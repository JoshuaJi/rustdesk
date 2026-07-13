//! C ABI for the pure Swift iOS client (no Flutter engine).
//!
//! Wraps the existing session engine (`flutter::session_*` / soft RGBA).
//! Event kinds: 0 = JSON string, 1 = rgba ready, 2 = close.

use crate::{
    flutter::{self, session_add, session_start_native},
    flutter_ffi::{
        main_init, session_change_prefer_codec, session_close, session_get_image_quality,
        session_get_toggle_option, session_input_key, session_input_string, session_login,
        session_peer_option, session_send_mouse, session_set_image_quality, session_set_size,
        session_toggle_option, SessionID,
    },
    ui_interface::{get_id, get_option, peer_to_map, set_option},
};
use hbb_common::{config::PeerConfig, log};
use std::{
    ffi::{CStr, CString},
    os::raw::{c_char, c_int, c_void},
    str::FromStr,
};

/// kind: 0=JSON, 1=rgba(display), 2=close
pub type RdEventCb = extern "C" fn(*mut c_void, c_int, *const c_char, usize);

fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

fn cstring_or_empty(p: *const c_char) -> String {
    cstr(p).unwrap_or("").to_owned()
}

fn parse_session_id(p: *const c_char) -> Option<SessionID> {
    let s = cstr(p)?;
    SessionID::from_str(s).ok()
}

/// Free a string returned by this ABI (allocated with CString).
#[no_mangle]
pub unsafe extern "C" fn rd_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub extern "C" fn rd_main_init(app_dir: *const c_char, custom_cfg: *const c_char) {
    let app = cstring_or_empty(app_dir);
    let cfg = cstring_or_empty(custom_cfg);
    main_init(app.clone(), cfg);
    // iOS data dir (same as Flutter path)
    let _ = crate::flutter_ffi::main_get_data_dir_ios(app);
    log::info!("rd_main_init done");
}

#[no_mangle]
pub extern "C" fn rd_main_get_id() -> *mut c_char {
    CString::new(get_id()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn rd_main_set_option(key: *const c_char, value: *const c_char) {
    let Some(k) = cstr(key) else { return };
    set_option(k.to_owned(), cstring_or_empty(value));
}

#[no_mangle]
pub extern "C" fn rd_main_get_option(key: *const c_char) -> *mut c_char {
    let Some(k) = cstr(key) else {
        return CString::new("").unwrap().into_raw();
    };
    CString::new(get_option(k))
        .unwrap_or_default()
        .into_raw()
}

/// Returns 0 on success, non-zero on failure. On failure, *err_out is set (free with rd_free_string).
#[no_mangle]
pub extern "C" fn rd_session_add(
    session_uuid: *const c_char,
    peer_id: *const c_char,
    password: *const c_char,
    force_relay: c_int,
    err_out: *mut *mut c_char,
) -> c_int {
    let Some(sid) = parse_session_id(session_uuid) else {
        set_err(err_out, "invalid session uuid");
        return -1;
    };
    let Some(id) = cstr(peer_id).map(|s| s.to_owned()) else {
        set_err(err_out, "missing peer id");
        return -1;
    };
    let password = cstring_or_empty(password);
    match session_add(
        &sid,
        &id,
        false,
        false,
        false,
        false,
        false,
        "",
        force_relay != 0,
        password,
        false,
        None,
    ) {
        Ok(_) => 0,
        Err(e) => {
            set_err(err_out, &format!("{e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn rd_session_start(
    session_uuid: *const c_char,
    peer_id: *const c_char,
    cb: Option<RdEventCb>,
    user: *mut c_void,
    err_out: *mut *mut c_char,
) -> c_int {
    let Some(sid) = parse_session_id(session_uuid) else {
        set_err(err_out, "invalid session uuid");
        return -1;
    };
    let Some(id) = cstr(peer_id).map(|s| s.to_owned()) else {
        set_err(err_out, "missing peer id");
        return -1;
    };
    let Some(cb) = cb else {
        set_err(err_out, "null event callback");
        return -1;
    };
    match session_start_native(&sid, &id, cb, user) {
        Ok(()) => 0,
        Err(e) => {
            set_err(err_out, &format!("{e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn rd_session_login(
    session_uuid: *const c_char,
    password: *const c_char,
    remember: c_int,
) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_login(
        sid,
        "".to_owned(),
        "".to_owned(),
        cstring_or_empty(password),
        remember != 0,
    );
}

#[no_mangle]
pub extern "C" fn rd_session_close(session_uuid: *const c_char) {
    if let Some(sid) = parse_session_id(session_uuid) {
        session_close(sid);
    }
}

#[no_mangle]
pub extern "C" fn rd_session_get_rgba_size(session_uuid: *const c_char, display: usize) -> usize {
    let Some(sid) = parse_session_id(session_uuid) else {
        return 0;
    };
    flutter::session_get_rgba_size(sid, display)
}

/// Existing soft-render pull; also re-exported for clarity.
#[no_mangle]
pub extern "C" fn rd_session_get_rgba(session_uuid: *const c_char, display: usize) -> *const u8 {
    // session_get_rgba expects *const char session uuid string
    crate::flutter::session_get_rgba(session_uuid as *const _, display)
}

#[no_mangle]
pub extern "C" fn rd_session_next_rgba(session_uuid: *const c_char, display: usize) {
    if let Some(sid) = parse_session_id(session_uuid) {
        flutter::session_next_rgba(sid, display);
    }
}

#[no_mangle]
pub extern "C" fn rd_session_set_size(
    session_uuid: *const c_char,
    display: usize,
    width: usize,
    height: usize,
) {
    if let Some(sid) = parse_session_id(session_uuid) {
        session_set_size(sid, display, width, height);
    }
}

/// Switch the captured remote display (0-based). Soft-renderer path captures
/// that single display; peer will send switch_display + new frames.
#[no_mangle]
pub extern "C" fn rd_session_switch_display(session_uuid: *const c_char, display: c_int) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    if display < 0 {
        return;
    }
    // Desktop remote: is_desktop=true. Routes through session handler display list.
    flutter::sessions::session_switch_display(true, sid, vec![display]);
}

#[no_mangle]
pub extern "C" fn rd_session_send_mouse(session_uuid: *const c_char, json: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_send_mouse(sid, cstring_or_empty(json));
}

#[no_mangle]
pub extern "C" fn rd_session_input_string(session_uuid: *const c_char, value: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_input_string(sid, cstring_or_empty(value));
}

/// Push text into the remote peer's system clipboard (true clipboard sync).
/// Prefer this over keystroke paste for large content / Cmd+V on the host.
#[no_mangle]
pub extern "C" fn rd_session_send_clipboard(session_uuid: *const c_char, text: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    let text = cstring_or_empty(text);
    if text.is_empty() {
        return;
    }
    if let Some(session) = flutter::sessions::get_session_by_session_id(&sid) {
        session.send_clipboard_text(&text);
    }
}

#[no_mangle]
pub extern "C" fn rd_session_input_key(
    session_uuid: *const c_char,
    name: *const c_char,
    down: c_int,
    press: c_int,
    alt: c_int,
    ctrl: c_int,
    shift: c_int,
    command: c_int,
) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_input_key(
        sid,
        cstring_or_empty(name),
        down != 0,
        press != 0,
        alt != 0,
        ctrl != 0,
        shift != 0,
        command != 0,
    );
}

#[no_mangle]
pub extern "C" fn rd_session_handle_key(
    session_uuid: *const c_char,
    character: *const c_char,
    usb_hid: c_int,
    lock_modes: c_int,
    down: c_int,
) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    if let Some(session) = flutter::sessions::get_session_by_session_id(&sid) {
        session.handle_flutter_key_event(
            "map",
            &cstring_or_empty(character),
            usb_hid,
            lock_modes,
            down != 0,
        );
    }
}

// MARK: - Session options (Phase 3)

#[no_mangle]
pub extern "C" fn rd_session_set_image_quality(session_uuid: *const c_char, value: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_set_image_quality(sid, cstring_or_empty(value));
}

#[no_mangle]
pub extern "C" fn rd_session_get_image_quality(session_uuid: *const c_char) -> *mut c_char {
    let Some(sid) = parse_session_id(session_uuid) else {
        return CString::new("").unwrap().into_raw();
    };
    let q = session_get_image_quality(sid).unwrap_or_default();
    CString::new(q).unwrap_or_default().into_raw()
}

/// Toggle peer options like "view-only", "show-remote-cursor", "disable-clipboard",
/// "disable-audio", "lock-after-session-end", "privacy-mode", etc.
#[no_mangle]
pub extern "C" fn rd_session_toggle_option(session_uuid: *const c_char, name: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_toggle_option(sid, cstring_or_empty(name));
}

/// Returns 1 if option is on, 0 if off/unknown.
#[no_mangle]
pub extern "C" fn rd_session_get_toggle_option(
    session_uuid: *const c_char,
    name: *const c_char,
) -> c_int {
    let Some(sid) = parse_session_id(session_uuid) else {
        return 0;
    };
    match session_get_toggle_option(sid, cstring_or_empty(name)) {
        Some(true) => 1,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn rd_session_set_peer_option(
    session_uuid: *const c_char,
    name: *const c_char,
    value: *const c_char,
) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_peer_option(sid, cstring_or_empty(name), cstring_or_empty(value));
}

/// Tell the host we can hard-decode H.264/H.265 (VideoToolbox) and re-negotiate codec.
/// Call after peer_info / when user changes codec preference.
#[no_mangle]
pub extern "C" fn rd_session_refresh_decodings(session_uuid: *const c_char) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    session_change_prefer_codec(sid);
}

/// Prefer host encode as H.264 / H.265 / auto so iOS VideoToolbox can decode.
#[no_mangle]
pub extern "C" fn rd_session_set_codec_preference(
    session_uuid: *const c_char,
    value: *const c_char,
) {
    let Some(sid) = parse_session_id(session_uuid) else {
        return;
    };
    let v = cstring_or_empty(value);
    // Peer-scoped option used by display settings on the host negotiate path.
    session_peer_option(sid, "codec-preference".to_owned(), v);
    session_change_prefer_codec(sid);
}

/// JSON array of recent peers from PeerConfig disk store.
/// Each object: id, username, hostname, platform, alias (password hash omitted).
#[no_mangle]
pub extern "C" fn rd_main_recent_peers_json() -> *mut c_char {
    let peers = PeerConfig::peers(None);
    let mut arr = Vec::new();
    for (id, _t, p) in peers.into_iter().take(40) {
        let mut m = peer_to_map(id, p);
        m.remove("hash"); // do not expose password material over ABI
        arr.push(m);
    }
    let s = serde_json::to_string(&arr).unwrap_or_else(|_| "[]".to_owned());
    CString::new(s).unwrap_or_default().into_raw()
}

fn set_err(err_out: *mut *mut c_char, msg: &str) {
    if err_out.is_null() {
        return;
    }
    unsafe {
        *err_out = CString::new(msg).unwrap_or_default().into_raw();
    }
}

/// Keep symbols from being stripped when linked into the app.
#[no_mangle]
pub extern "C" fn rd_force_link() {
    let _ = (
        rd_main_init as *const (),
        rd_session_add as *const (),
        rd_session_start as *const (),
        rd_session_set_image_quality as *const (),
        rd_session_toggle_option as *const (),
        rd_session_refresh_decodings as *const (),
        rd_session_set_codec_preference as *const (),
        rd_session_send_clipboard as *const (),
        rd_session_switch_display as *const (),
        rd_main_recent_peers_json as *const (),
        crate::flutter::session_get_rgba as *const (),
    );
}
