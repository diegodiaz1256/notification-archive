//! Captures notification avatars that would otherwise be lost.
//!
//! A sender can deliver its image as raw pixels in the freedesktop
//! `image-data` hint rather than as a file path. Brave does this for WhatsApp
//! web notifications, so the contact photo shows on the toast and nowhere
//! afterwards: Quickshell turns those pixels into an in-process `image://`
//! URL that dies with the notification, and it strips the hint from the map
//! it exposes to QML, so the shell cannot reach the pixels to save them.
//!
//! This daemon watches the session bus as a passive monitor and writes those
//! pixels to a PNG. `BecomeMonitor` is read-only: it never owns the
//! notification bus name, so the shell's own daemon keeps receiving and
//! displaying every notification exactly as before. If this process is not
//! running, nothing changes except that avatars are not saved.
//!
//! Files land in their own `avatars/` directory, NOT in the `images/` one the
//! shell uses for its own copies: the shell sweeps that directory at startup
//! and deletes anything without a matching notification JSON, which every file
//! written here would be.
//!
//! They are named `<app>-<summary hash>.png`. The shell names its own copies
//! after a notification id this process never sees (the monitor observes the
//! method call, the id is assigned in the reply), so this matches on what both
//! sides do have: the sending app and its summary. Two messages from the same
//! contact collide on that name, which is correct -- it is the same photo, and
//! the newer write keeps it current.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use dbus::blocking::Connection;
use dbus::channel::MatchingReceiver;
use dbus::message::MatchRule;
use dbus::Message;
use flate2::write::ZlibEncoder;
use flate2::Compression;

/// Refuse anything larger than this per side. An avatar is tens of pixels;
/// a hint claiming more is either a decoded photo nobody wants on disk or a
/// malformed message, and allocating for it helps no one.
const MAX_DIMENSION: i32 = 512;

/// A hard ceiling on the directory, in case a machine sees an implausible
/// number of distinct senders inside the retention window.
const MAX_FILES: usize = 500;

/// Matches the archive's own thirty-day window: an avatar outlives the
/// notification it arrived with, because the same contact's next message
/// reuses it, but there is no reason to keep one for a contact who has not
/// been in touch for longer than the entries it would illustrate.
const MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);

fn main() {
    let dir = match avatar_dir() {
        Some(dir) => dir,
        None => {
            eprintln!("notification-avatar-daemon: no HOME, nothing to do");
            std::process::exit(1);
        }
    };
    if let Err(err) = fs::create_dir_all(&dir) {
        eprintln!("notification-avatar-daemon: cannot create {dir:?}: {err}");
        std::process::exit(1);
    }

    let conn = match Connection::new_session() {
        Ok(conn) => conn,
        Err(err) => {
            eprintln!("notification-avatar-daemon: no session bus: {err}");
            std::process::exit(1);
        }
    };

    // BecomeMonitor asks the bus to copy matching messages here. It is the
    // supported replacement for the old eavesdrop match rule, which modern
    // dbus rejects outright.
    let rule = MatchRule::new_method_call()
        .with_interface("org.freedesktop.Notifications")
        .with_member("Notify");
    let proxy = conn.with_proxy(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        Duration::from_secs(5),
    );
    let become_monitor: Result<(), _> = proxy.method_call(
        "org.freedesktop.DBus.Monitoring",
        "BecomeMonitor",
        (vec![rule.match_str()], 0u32),
    );
    if let Err(err) = become_monitor {
        eprintln!("notification-avatar-daemon: BecomeMonitor refused: {err}");
        std::process::exit(1);
    }

    // A monitor receives every message the bus copies to it, and those copies
    // do not match a normal receive rule: the rule above is what the bus
    // filters on, this one is what this connection accepts, and in monitor
    // mode it has to accept everything and sort messages out by hand.
    conn.start_receive(
        MatchRule::new(),
        Box::new(move |msg, _| {
            let is_notify = msg.interface().is_some_and(|i| &*i == "org.freedesktop.Notifications")
                && msg.member().is_some_and(|m| &*m == "Notify");
            if is_notify {
                // One bad message must never take the daemon down: it would
                // stop capturing every later avatar too.
                if let Err(err) = handle(&msg, &dir) {
                    eprintln!("notification-avatar-daemon: {err}");
                }
            }
            true
        }),
    );

    loop {
        if conn.process(Duration::from_millis(1000)).is_err() {
            // The bus went away, which happens when the session ends.
            break;
        }
    }
}

fn avatar_dir() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(state.join("omarchy/notifications/avatars"))
}

fn handle(msg: &Message, dir: &PathBuf) -> Result<(), String> {
    // Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, timeout)
    let app: String = msg.read1().map_err(|e| format!("bad Notify args: {e}"))?;
    let mut iter = msg.iter_init();
    let mut fields = Vec::new();
    for _ in 0..7 {
        fields.push(iter.get_refarg());
        iter.next();
    }

    let summary = fields
        .get(3)
        .and_then(|f| f.as_ref())
        .and_then(|f| f.as_str())
        .unwrap_or("")
        .to_string();

    let hints = match fields.get(6).and_then(|f| f.as_ref()) {
        Some(hints) => hints,
        None => return Ok(()),
    };

    // The hint is a dict; the value we want is one of three spellings,
    // depending on how old the sender's libnotify is.
    let mut image: Option<&dyn dbus::arg::RefArg> = None;
    if let Some(mut entries) = hints.as_iter() {
        while let Some(key) = entries.next() {
            let value = match entries.next() {
                Some(value) => value,
                None => break,
            };
            match key.as_str() {
                Some("image-data") | Some("image_data") | Some("icon_data") => {
                    let modern = key.as_str() == Some("image-data");
                    image = Some(value);
                    // image-data wins over the older spellings, so stop on the
                    // modern one and let the others be overwritten.
                    if modern {
                        break;
                    }
                }
                _ => {}
            }
        }
    }

    let image = match image {
        Some(image) => image,
        None => return Ok(()),
    };

    let pixels = match decode(image) {
        Some(pixels) => pixels,
        None => return Ok(()),
    };

    let path = dir.join(format!("{}.png", stem(&app, &summary)));
    let png = encode_png(&pixels)?;

    // Created per write, not once at startup: the directory lives under
    // ~/.local/state and can be cleared by the user, a cleanup script, or a
    // fresh profile at any point in this process's lifetime, and a daemon
    // that only checked once would then fail silently forever.
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {parent:?}: {e}"))?;
    }

    // Write through a temporary file: the shell may read this directory at
    // any moment, and a half-written PNG renders as a broken image.
    let tmp = path.with_extension("png.tmp");
    fs::write(&tmp, &png).map_err(|e| format!("write {tmp:?}: {e}"))?;
    fs::rename(&tmp, &path).map_err(|e| format!("rename {path:?}: {e}"))?;

    trim(dir);
    Ok(())
}

struct Rgba {
    width: u32,
    height: u32,
    data: Vec<u8>,
}

/// The `image-data` hint is `(iiibiiay)`: width, height, rowstride, has_alpha,
/// bits per sample, channels, then the pixels themselves.
fn decode(arg: &dyn dbus::arg::RefArg) -> Option<Rgba> {
    // A hint value arrives as a variant wrapping the struct, so iterating the
    // variant itself yields one element: the struct. Step through it first,
    // and tolerate a value that is already the struct.
    let mut outer = arg.as_iter()?;
    let first = outer.next()?;
    let mut iter = if first.signature().starts_with('(') {
        first.as_iter()?
    } else {
        // Already unwrapped: restart on the original.
        arg.as_iter()?
    };
    let width = iter.next()?.as_i64()? as i32;
    let height = iter.next()?.as_i64()? as i32;
    let stride = iter.next()?.as_i64()? as i32;
    let _has_alpha = iter.next()?.as_i64()?;
    let bits = iter.next()?.as_i64()? as i32;
    let channels = iter.next()?.as_i64()? as i32;
    let bytes = iter.next()?;

    // Only 8 bits per sample exists in practice, and anything else would need
    // a conversion this daemon has no reason to carry.
    if bits != 8 || !(3..=4).contains(&channels) {
        return None;
    }
    if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return None;
    }

    // Collect the byte array. as_iter on a `ay` yields one entry per byte.
    let raw: Vec<u8> = bytes
        .as_iter()?
        .filter_map(|b| b.as_i64())
        .map(|b| b as u8)
        .collect();

    let width_usize = width as usize;
    let height_usize = height as usize;
    let channels_usize = channels as usize;
    let stride_usize = if stride > 0 {
        stride as usize
    } else {
        width_usize * channels_usize
    };

    // A stride that does not fit the data it describes means the hint is
    // malformed; indexing on it would panic.
    if stride_usize < width_usize * channels_usize
        || raw.len() < stride_usize * (height_usize - 1) + width_usize * channels_usize
    {
        return None;
    }

    let mut data = Vec::with_capacity(width_usize * height_usize * 4);
    for y in 0..height_usize {
        let row = &raw[y * stride_usize..];
        for x in 0..width_usize {
            let px = &row[x * channels_usize..];
            data.push(px[0]);
            data.push(px[1]);
            data.push(px[2]);
            data.push(if channels_usize == 4 { px[3] } else { 255 });
        }
    }

    Some(Rgba {
        width: width as u32,
        height: height as u32,
        data,
    })
}

fn encode_png(img: &Rgba) -> Result<Vec<u8>, String> {
    fn chunk(out: &mut Vec<u8>, tag: &[u8; 4], body: &[u8]) {
        out.extend_from_slice(&(body.len() as u32).to_be_bytes());
        out.extend_from_slice(tag);
        out.extend_from_slice(body);
        let mut crc = crc32(tag);
        crc = crc32_update(crc, body);
        out.extend_from_slice(&(crc ^ 0xffff_ffff).to_be_bytes());
    }

    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&img.width.to_be_bytes());
    header.extend_from_slice(&img.height.to_be_bytes());
    header.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA, no interlace

    // Each scanline is prefixed with its filter type; 0 means "none", which
    // costs a little size and saves carrying a filter implementation.
    let stride = img.width as usize * 4;
    let mut raw = Vec::with_capacity(img.data.len() + img.height as usize);
    for y in 0..img.height as usize {
        raw.push(0);
        raw.extend_from_slice(&img.data[y * stride..(y + 1) * stride]);
    }

    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(&raw)
        .map_err(|e| format!("deflate: {e}"))?;
    let deflated = encoder.finish().map_err(|e| format!("deflate: {e}"))?;

    let mut out = Vec::with_capacity(deflated.len() + 64);
    out.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
    chunk(&mut out, b"IHDR", &header);
    chunk(&mut out, b"IDAT", &deflated);
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}

fn crc32(bytes: &[u8]) -> u32 {
    crc32_update(0xffff_ffff, bytes)
}

fn crc32_update(mut crc: u32, bytes: &[u8]) -> u32 {
    for &byte in bytes {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    crc
}

/// The shell names its files after a notification id this process never sees:
/// the monitor observes the method call, and the id is assigned in the reply.
/// App and summary are what both sides do have, and together they identify
/// the sender and the contact the avatar belongs to.
///
/// The panel has to derive this same name to find the file, so the hash must
/// be one it can reproduce. FNV-1a over the summary's UTF-8 bytes is specified
/// and a few lines in any language; Rust's DefaultHasher is neither, since its
/// algorithm is explicitly an unstable implementation detail that a compiler
/// upgrade may change, which would orphan every file already written.
fn stem(app: &str, summary: &str) -> String {
    let safe: String = app
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .take(40)
        .collect();
    format!("avatar-{}-{:016x}", safe, fnv1a(summary))
}

/// FNV-1a, 64-bit, over UTF-8 bytes. Chosen for being reproducible elsewhere
/// rather than for collision resistance: a collision here means two contacts
/// of the same app sharing an avatar, which the next capture corrects.
fn fnv1a(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Expire avatars that have outlived their usefulness.
///
/// Two rules, both needed. Age is the real one: an avatar is worth keeping
/// while the contact is still in touch, and MAX_AGE matches the window the
/// archive keeps entries for, so a photo cannot outlive every notification it
/// would illustrate. The count cap is a backstop for a machine that somehow
/// sees more distinct senders than that inside the window.
///
/// A file is touched on every write, so "last modified" is "last seen from
/// this sender", which is exactly the age that matters.
fn trim(dir: &PathBuf) {
    let now = SystemTime::now();
    let mut ours: Vec<(SystemTime, PathBuf)> = match fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with("avatar-") && name.ends_with(".png"))
            })
            .filter_map(|entry| {
                let modified = entry.metadata().ok()?.modified().ok()?;
                Some((modified, entry.path()))
            })
            .collect(),
        Err(_) => return,
    };

    // Age first, so the count cap only ever has to consider live files.
    ours.retain(|(modified, path)| {
        let stale = now
            .duration_since(*modified)
            .map(|age| age > MAX_AGE)
            .unwrap_or(false);
        if stale {
            let _ = fs::remove_file(path);
        }
        !stale
    });

    if ours.len() <= MAX_FILES {
        return;
    }
    ours.sort_by_key(|(modified, _)| *modified);
    for (_, path) in ours.iter().take(ours.len() - MAX_FILES) {
        let _ = fs::remove_file(path);
    }
}

