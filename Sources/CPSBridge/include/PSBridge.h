// PSBridge: the only doorway to the protocol core (libchiaki).
// Self-contained on purpose: no chiaki types appear here, so the core can be replaced later
// without touching anything above this header.

#ifndef PS_BRIDGE_H
#define PS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ───────────────────────────── Logging ─────────────────────────────

// Levels are a bitmask: error = 1, warning = 2, info = 4, verbose = 8, debug = 16.
#define PS_LOG_ERROR 1u
#define PS_LOG_WARNING 2u
#define PS_LOG_INFO 4u
#define PS_LOG_VERBOSE 8u
#define PS_LOG_DEBUG 16u

typedef void (*PSLogCallback)(uint32_t level, const char *msg, void *user);

/// Installs the process-wide log callback. Called from arbitrary threads. Pass NULL to log to stderr.
void ps_log_set_callback(PSLogCallback cb, void *user, uint32_t level_mask);

/// Human readable text for an error code returned by the functions below (0 = success).
const char *ps_error_string(int32_t code);

// ──────────────────────────── Discovery ────────────────────────────

#define PS_HOST_STATE_UNKNOWN 0
#define PS_HOST_STATE_READY 1
#define PS_HOST_STATE_STANDBY 2

typedef struct {
	int32_t state;
	uint16_t request_port;
	bool ps5;
	/// Protocol target for this console's firmware; pass it on to registration and sessions.
	uint32_t target;
	// All strings may be NULL and are only valid during the callback.
	const char *host_addr;
	const char *host_name;
	const char *host_type;
	const char *host_id; // 12 hex digits (MAC)
	const char *system_version;
	const char *running_app_titleid;
	const char *running_app_name;
} PSDiscoveredHost;

/// Called on a background thread with the complete current host list whenever it changes.
typedef void (*PSDiscoveryCallback)(const PSDiscoveredHost *hosts, size_t count, void *user);

typedef struct PSDiscovery PSDiscovery;

/// Starts periodic LAN discovery (broadcast, PS4 + PS5). Returns NULL on failure (err set).
PSDiscovery *ps_discovery_start(PSDiscoveryCallback cb, void *user, int32_t *err);
/// Stops discovery and frees it. The callback is not invoked after this returns.
void ps_discovery_stop(PSDiscovery *discovery);

/// Sends the wake packet to a console in standby. `regist_key` is the 16 byte key from pairing.
int32_t ps_wakeup(const char *host, const uint8_t regist_key[16], bool ps5);

// ─────────────────────────── Registration ──────────────────────────

typedef struct {
	uint32_t target;
	uint8_t server_mac[6];
	char server_nickname[0x20]; // zero terminated
	uint8_t rp_regist_key[16];  // zero padded
	uint32_t rp_key_type;
	uint8_t rp_key[16];
	char ap_ssid[0x30];
	char ap_bssid[0x20];
	char ap_key[0x50];
	char ap_name[0x20];
	uint32_t console_pin;
} PSRegisteredHost;

#define PS_REGIST_RESULT_SUCCESS 0
#define PS_REGIST_RESULT_FAILED 1
#define PS_REGIST_RESULT_CANCELED 2

/// Called exactly once on a background thread. `host` is non-NULL only on success and only
/// valid during the callback.
typedef void (*PSRegistCallback)(int32_t result, const PSRegisteredHost *host, void *user);

typedef struct PSRegist PSRegist;

/// Starts pairing with a console that is showing the "Link Device" PIN.
/// @param host            IP address or hostname of the console
/// @param target          from PSDiscoveredHost.target
/// @param psn_account_id  the 8 byte PSN account id
/// @param pin             the 8 digit PIN shown on the console, as a number
/// @param console_pin     console login PIN if the user has one set, otherwise 0
PSRegist *ps_regist_start(const char *host, uint32_t target, const uint8_t psn_account_id[8], uint32_t pin, uint32_t console_pin, PSRegistCallback cb, void *user, int32_t *err);

/// Cancels (if still running), waits for the worker to finish and frees. Always call this once,
/// also after the callback fired. Must not be called from inside the callback.
void ps_regist_destroy(PSRegist *regist);

// ───────────────────────────── Session ─────────────────────────────

#define PS_CODEC_H264 0
#define PS_CODEC_H265 1
#define PS_CODEC_H265_HDR 2

typedef struct {
	const char *host;
	bool ps5;
	uint8_t regist_key[16];
	uint8_t rp_key[16];
	uint8_t psn_account_id[8];

	uint32_t width;
	uint32_t height;
	uint32_t max_fps;
	uint32_t bitrate_kbps;
	int32_t codec; // PS_CODEC_*

	/// Ask for DualSense features (haptics stream, adaptive triggers). PS5 only.
	bool enable_dualsense;
	bool enable_keyboard;
	/// Let the core fall back to a lower profile if the console refuses the requested one.
	bool auto_downgrade;
	/// Maximum tolerated packet loss (0...1) used by congestion control reporting.
	double packet_loss_max;
	bool enable_idr_on_fec_failure;
} PSSessionConfig;

typedef struct {
	uint16_t x, y;
	int8_t id; // -1 = up
} PSControllerTouch;

typedef struct {
	uint32_t buttons;
	uint8_t l2;
	uint8_t r2;
	int16_t left_x, left_y, right_x, right_y;
	uint8_t touch_id_next;
	PSControllerTouch touch0;
	PSControllerTouch touch1;
	float gyro_x, gyro_y, gyro_z;
	float accel_x, accel_y, accel_z;
	float orient_x, orient_y, orient_z, orient_w;
} PSControllerState;

#define PS_EVENT_CONNECTED 0
#define PS_EVENT_LOGIN_PIN_REQUEST 1
#define PS_EVENT_NICKNAME_RECEIVED 2
#define PS_EVENT_RUMBLE 3
#define PS_EVENT_QUIT 4
#define PS_EVENT_TRIGGER_EFFECTS 5
#define PS_EVENT_MOTION_RESET 6
#define PS_EVENT_LED_COLOR 7
#define PS_EVENT_PLAYER_INDEX 8
#define PS_EVENT_KEYBOARD_OPEN 9
#define PS_EVENT_KEYBOARD_TEXT_CHANGE 10
#define PS_EVENT_KEYBOARD_REMOTE_CLOSE 11
#define PS_EVENT_VIDEO_FEC_FAILURE 12
#define PS_EVENT_CANT_DISPLAY 13
#define PS_EVENT_HAPTIC_INTENSITY 14
#define PS_EVENT_TRIGGER_INTENSITY 15

typedef struct {
	int32_t type; // PS_EVENT_*

	// LOGIN_PIN_REQUEST
	bool pin_incorrect;

	// QUIT
	int32_t quit_reason;
	bool quit_is_error;
	const char *quit_reason_string; // static description of quit_reason
	const char *quit_detail;        // extra text from the console, may be NULL

	// NICKNAME_RECEIVED / KEYBOARD_TEXT_CHANGE
	const char *text;

	// RUMBLE
	uint8_t rumble_left;
	uint8_t rumble_right;

	// TRIGGER_EFFECTS
	uint8_t trigger_type_left;
	uint8_t trigger_type_right;
	uint8_t trigger_left[10];
	uint8_t trigger_right[10];

	// LED_COLOR
	uint8_t led[3];

	// PLAYER_INDEX
	uint8_t player_index;

	// HAPTIC_INTENSITY / TRIGGER_INTENSITY: 0 = off, 1 = weak, 2 = medium, 3 = strong
	int32_t intensity;

	// CANT_DISPLAY: the console is showing content it refuses to stream
	bool cant_display;
} PSEvent;

// All callbacks run on core threads. Pointers are only valid during the call.
typedef struct {
	void *user;
	void (*event)(const PSEvent *event, void *user);
	/// One Annex-B buffer; the first of a session is the parameter set header. Return false to
	/// report a corrupt frame (the console then sends a keyframe).
	bool (*video)(const uint8_t *buf, size_t size, int32_t frames_lost, bool frame_recovered, void *user);
	void (*audio_config)(uint32_t channels, uint32_t rate, void *user);
	/// Decoded interleaved S16 PCM; `samples` is the frame count per channel.
	void (*audio_frame)(const int16_t *pcm, size_t samples, void *user);
	/// DualSense haptics: interleaved S16 stereo at 3 kHz; `samples` is the frame count per channel.
	void (*haptics_frame)(const int16_t *pcm, size_t samples, void *user);
} PSSessionCallbacks;

typedef struct {
	/// Bitrate measured over the last interval, in bit/s.
	double measured_bitrate;
	/// Packet loss over the last interval, 0...1.
	double packet_loss;
	uint64_t rtt_us;
	uint32_t mtu_in;
	uint32_t mtu_out;
} PSSessionStats;

typedef struct PSSession PSSession;

PSSession *ps_session_create(const PSSessionConfig *config, const PSSessionCallbacks *callbacks, int32_t *err);
int32_t ps_session_start(PSSession *session);
/// Asks the session to end; the QUIT event follows. Safe from any thread except inside a callback.
int32_t ps_session_stop(PSSession *session);
/// Stops if needed, waits for the session thread and frees everything.
/// Must not be called from inside a callback.
void ps_session_destroy(PSSession *session);

int32_t ps_session_set_controller_state(PSSession *session, const PSControllerState *state);
int32_t ps_session_set_login_pin(PSSession *session, const char *pin_digits);
int32_t ps_session_request_idr(PSSession *session);
/// Put the console into rest mode.
int32_t ps_session_goto_bed(PSSession *session);
int32_t ps_session_go_home(PSSession *session);
int32_t ps_session_keyboard_set_text(PSSession *session, const char *text);
int32_t ps_session_keyboard_accept(PSSession *session);
int32_t ps_session_keyboard_reject(PSSession *session);
void ps_session_get_stats(PSSession *session, PSSessionStats *out);

#ifdef __cplusplus
}
#endif

#endif // PS_BRIDGE_H
