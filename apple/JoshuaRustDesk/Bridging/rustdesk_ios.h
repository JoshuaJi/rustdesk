#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// kind: 0 = JSON event string, 1 = rgba frame ready (display index), 2 = session closed
typedef void (*rd_event_cb)(void *user, int kind, const char *json, size_t display);

void rd_free_string(char *s);

void rd_main_init(const char *app_dir, const char *custom_cfg);
char *rd_main_get_id(void);
void rd_main_set_option(const char *key, const char *value);
char *rd_main_get_option(const char *key);

int rd_session_add(const char *session_uuid, const char *peer_id, const char *password,
                   int force_relay, char **err_out);
int rd_session_start(const char *session_uuid, const char *peer_id, rd_event_cb cb, void *user,
                     char **err_out);
void rd_session_login(const char *session_uuid, const char *password, int remember);
void rd_session_close(const char *session_uuid);

size_t rd_session_get_rgba_size(const char *session_uuid, size_t display);
const uint8_t *rd_session_get_rgba(const char *session_uuid, size_t display);
const uint8_t *session_get_rgba(const char *session_uuid, size_t display);
void rd_session_next_rgba(const char *session_uuid, size_t display);
void rd_session_set_size(const char *session_uuid, size_t display, size_t width, size_t height);

void rd_session_send_mouse(const char *session_uuid, const char *json);
void rd_session_input_string(const char *session_uuid, const char *value);
void rd_session_input_key(const char *session_uuid, const char *name, int down, int press, int alt,
                          int ctrl, int shift, int command);
void rd_session_handle_key(const char *session_uuid, const char *character, int usb_hid,
                           int lock_modes, int down);

void rd_force_link(void);

#ifdef __cplusplus
}
#endif
