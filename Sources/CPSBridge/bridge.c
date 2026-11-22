// Implementation of PSBridge.h on top of libchiaki (vendor/chiaki-ng, AGPL-3.0).

#include "PSBridge.h"

#include <chiaki/common.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

// ───────────────────────────── Logging ─────────────────────────────

static ChiakiLog g_log;
static PSLogCallback g_log_cb;
static void *g_log_user;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void log_trampoline(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	PSLogCallback cb = g_log_cb;
	if(cb)
		cb((uint32_t)level, msg, g_log_user);
	else
		chiaki_log_cb_print(level, msg, NULL);
}

static void global_init(void)
{
	chiaki_lib_init();
	chiaki_log_init(&g_log, CHIAKI_LOG_ALL & ~(CHIAKI_LOG_VERBOSE | CHIAKI_LOG_DEBUG), log_trampoline, NULL);
}

static ChiakiLog *core_log(void)
{
	pthread_once(&g_once, global_init);
	return &g_log;
}

void ps_log_set_callback(PSLogCallback cb, void *user, uint32_t level_mask)
{
	ChiakiLog *log = core_log();
	g_log_user = user;
	g_log_cb = cb;
	chiaki_log_set_level(log, level_mask);
}

const char *ps_error_string(int32_t code)
{
	return chiaki_error_string((ChiakiErrorCode)code);
}

// ──────────────────────────── Discovery ────────────────────────────

#define PS_DISCOVERY_PING_MS 500
#define PS_DISCOVERY_HOSTS_MAX 16
#define PS_DISCOVERY_DROP_PINGS 3

struct PSDiscovery
{
	ChiakiDiscoveryService service;
	PSDiscoveryCallback cb;
	void *user;
};

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user)
{
	PSDiscovery *discovery = user;
	PSDiscoveredHost out[PS_DISCOVERY_HOSTS_MAX];
	if(hosts_count > PS_DISCOVERY_HOSTS_MAX)
		hosts_count = PS_DISCOVERY_HOSTS_MAX;
	for(size_t i = 0; i < hosts_count; i++)
	{
		ChiakiDiscoveryHost *h = &hosts[i];
		PSDiscoveredHost *o = &out[i];
		memset(o, 0, sizeof(*o));
		switch(h->state)
		{
			case CHIAKI_DISCOVERY_HOST_STATE_READY:
				o->state = PS_HOST_STATE_READY;
				break;
			case CHIAKI_DISCOVERY_HOST_STATE_STANDBY:
				o->state = PS_HOST_STATE_STANDBY;
				break;
			default:
				o->state = PS_HOST_STATE_UNKNOWN;
				break;
		}
		o->request_port = h->host_request_port;
		o->ps5 = chiaki_discovery_host_is_ps5(h);
		o->target = (uint32_t)chiaki_discovery_host_system_version_target(h);
		o->host_addr = h->host_addr;
		o->host_name = h->host_name;
		o->host_type = h->host_type;
		o->host_id = h->host_id;
		o->system_version = h->system_version;
		o->running_app_titleid = h->running_app_titleid;
		o->running_app_name = h->running_app_name;
	}
	discovery->cb(out, hosts_count, discovery->user);
}

PSDiscovery *ps_discovery_start(PSDiscoveryCallback cb, void *user, int32_t *err)
{
	ChiakiLog *log = core_log();
	PSDiscovery *discovery = calloc(1, sizeof(PSDiscovery));
	if(!discovery)
	{
		if(err)
			*err = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	discovery->cb = cb;
	discovery->user = user;

	ChiakiDiscoveryServiceOptions options = { 0 };
	options.ping_ms = PS_DISCOVERY_PING_MS;
	options.hosts_max = PS_DISCOVERY_HOSTS_MAX;
	options.host_drop_pings = PS_DISCOVERY_DROP_PINGS;
	options.cb = discovery_cb;
	options.cb_user = discovery;

	struct sockaddr_in in_addr = { 0 };
	in_addr.sin_family = AF_INET;
	in_addr.sin_addr.s_addr = 0xffffffff; // 255.255.255.255
	struct sockaddr_storage addr = { 0 };
	memcpy(&addr, &in_addr, sizeof(in_addr));
	options.send_addr = &addr;
	options.send_addr_size = sizeof(in_addr);

	// Directed broadcast on every active interface, so consoles are found even when the
	// limited broadcast address is routed out of the wrong interface.
	struct sockaddr_storage broadcast[16];
	size_t broadcast_num = 0;
	struct ifaddrs *ifaddrs_list = NULL;
	if(getifaddrs(&ifaddrs_list) == 0)
	{
		for(struct ifaddrs *cur = ifaddrs_list; cur && broadcast_num < 16; cur = cur->ifa_next)
		{
			if(!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET || !cur->ifa_broadaddr)
				continue;
			if((cur->ifa_flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK | IFF_BROADCAST)) != (IFF_UP | IFF_RUNNING | IFF_BROADCAST))
				continue;
			in_addr_t baddr = ((struct sockaddr_in *)cur->ifa_broadaddr)->sin_addr.s_addr;
			bool known = false;
			for(size_t i = 0; i < broadcast_num; i++)
			{
				if(((struct sockaddr_in *)&broadcast[i])->sin_addr.s_addr == baddr)
				{
					known = true;
					break;
				}
			}
			if(known)
				continue;
			struct sockaddr_in b = { 0 };
			b.sin_family = AF_INET;
			b.sin_addr.s_addr = baddr;
			memset(&broadcast[broadcast_num], 0, sizeof(broadcast[0]));
			memcpy(&broadcast[broadcast_num], &b, sizeof(b));
			broadcast_num++;
		}
		freeifaddrs(ifaddrs_list);
	}
	options.broadcast_addrs = broadcast_num ? broadcast : NULL;
	options.broadcast_num = broadcast_num;

	ChiakiErrorCode r = chiaki_discovery_service_init(&discovery->service, &options, log);
	if(err)
		*err = r;
	if(r != CHIAKI_ERR_SUCCESS)
	{
		free(discovery);
		return NULL;
	}
	return discovery;
}

void ps_discovery_stop(PSDiscovery *discovery)
{
	if(!discovery)
		return;
	chiaki_discovery_service_fini(&discovery->service);
	free(discovery);
}

int32_t ps_wakeup(const char *host, const uint8_t regist_key[16], bool ps5)
{
	// The wake credential is the regist key, which is an ASCII hex string of at most
	// 8 characters padded with zero bytes, read as a number.
	char key[17];
	memcpy(key, regist_key, 16);
	key[16] = '\0';
	size_t len = strlen(key);
	if(len == 0 || len > 8)
		return CHIAKI_ERR_INVALID_DATA;
	char *end = NULL;
	uint64_t credential = strtoull(key, &end, 16);
	if(!end || *end != '\0')
		return CHIAKI_ERR_INVALID_DATA;
	return chiaki_discovery_wakeup(core_log(), NULL, host, credential, ps5);
}

// ─────────────────────────── Registration ──────────────────────────

struct PSRegist
{
	ChiakiRegist regist;
	PSRegistCallback cb;
	void *user;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	PSRegist *regist = user;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			if(!event->registered_host)
			{
				regist->cb(PS_REGIST_RESULT_FAILED, NULL, regist->user);
				break;
			}
			ChiakiRegisteredHost *h = event->registered_host;
			PSRegisteredHost out;
			memset(&out, 0, sizeof(out));
			out.target = (uint32_t)h->target;
			memcpy(out.server_mac, h->server_mac, sizeof(out.server_mac));
			memcpy(out.server_nickname, h->server_nickname, sizeof(out.server_nickname));
			out.server_nickname[sizeof(out.server_nickname) - 1] = '\0';
			memcpy(out.rp_regist_key, h->rp_regist_key, sizeof(out.rp_regist_key));
			out.rp_key_type = h->rp_key_type;
			memcpy(out.rp_key, h->rp_key, sizeof(out.rp_key));
			memcpy(out.ap_ssid, h->ap_ssid, sizeof(out.ap_ssid));
			memcpy(out.ap_bssid, h->ap_bssid, sizeof(out.ap_bssid));
			memcpy(out.ap_key, h->ap_key, sizeof(out.ap_key));
			memcpy(out.ap_name, h->ap_name, sizeof(out.ap_name));
			out.console_pin = h->console_pin;
			regist->cb(PS_REGIST_RESULT_SUCCESS, &out, regist->user);
			break;
		}
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			regist->cb(PS_REGIST_RESULT_CANCELED, NULL, regist->user);
			break;
		default:
			regist->cb(PS_REGIST_RESULT_FAILED, NULL, regist->user);
			break;
	}
}

PSRegist *ps_regist_start(const char *host, uint32_t target, const uint8_t psn_account_id[8], uint32_t pin, uint32_t console_pin, PSRegistCallback cb, void *user, int32_t *err)
{
	ChiakiLog *log = core_log();
	PSRegist *regist = calloc(1, sizeof(PSRegist));
	if(!regist)
	{
		if(err)
			*err = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	regist->cb = cb;
	regist->user = user;

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = (ChiakiTarget)target;
	info.host = host; // copied by chiaki_regist_start
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = console_pin;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiErrorCode r = chiaki_regist_start(&regist->regist, log, &info, regist_cb, regist);
	if(err)
		*err = r;
	if(r != CHIAKI_ERR_SUCCESS)
	{
		free(regist);
		return NULL;
	}
	return regist;
}

void ps_regist_destroy(PSRegist *regist)
{
	if(!regist)
		return;
	chiaki_regist_stop(&regist->regist);
	chiaki_regist_fini(&regist->regist); // joins the worker thread
	free(regist);
}

// ───────────────────────────── Session ─────────────────────────────

struct PSSession
{
	ChiakiSession session;
	ChiakiOpusDecoder opus_decoder;
	PSSessionCallbacks cbs;
	char *host;
	bool started;
	bool joined;
};

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	PSSession *s = user;
	if(!s->cbs.video)
		return true;
	return s->cbs.video(buf, buf_size, frames_lost, frame_recovered, s->cbs.user);
}

static void session_audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	PSSession *s = user;
	if(s->cbs.audio_config)
		s->cbs.audio_config(channels, rate, s->cbs.user);
}

static void session_audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	PSSession *s = user;
	if(s->cbs.audio_frame)
		s->cbs.audio_frame(buf, samples_count, s->cbs.user);
}

static void session_haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	PSSession *s = user;
	if(!s->cbs.haptics_frame || buf_size < 2 * sizeof(int16_t) || (buf_size % (2 * sizeof(int16_t))) != 0)
		return;
	s->cbs.haptics_frame((const int16_t *)buf, buf_size / (2 * sizeof(int16_t)), s->cbs.user);
}

static void session_cant_display_cb(void *user, bool cant_display)
{
	PSSession *s = user;
	if(!s->cbs.event)
		return;
	PSEvent out;
	memset(&out, 0, sizeof(out));
	out.type = PS_EVENT_CANT_DISPLAY;
	out.cant_display = cant_display;
	s->cbs.event(&out, s->cbs.user);
}

static int32_t map_intensity(ChiakiDualSenseEffectIntensity intensity)
{
	switch(intensity)
	{
		case Strong:
			return 3;
		case Medium:
			return 2;
		case Weak:
			return 1;
		default:
			return 0;
	}
}

static void session_event_cb(ChiakiEvent *event, void *user)
{
	PSSession *s = user;
	if(!s->cbs.event)
		return;
	PSEvent out;
	memset(&out, 0, sizeof(out));
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			out.type = PS_EVENT_CONNECTED;
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			out.type = PS_EVENT_LOGIN_PIN_REQUEST;
			out.pin_incorrect = event->login_pin_request.pin_incorrect;
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			out.type = PS_EVENT_NICKNAME_RECEIVED;
			out.text = event->server_nickname;
			break;
		case CHIAKI_EVENT_KEYBOARD_OPEN:
			out.type = PS_EVENT_KEYBOARD_OPEN;
			break;
		case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
			out.type = PS_EVENT_KEYBOARD_TEXT_CHANGE;
			out.text = event->keyboard.text_str;
			break;
		case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
			out.type = PS_EVENT_KEYBOARD_REMOTE_CLOSE;
			break;
		case CHIAKI_EVENT_RUMBLE:
			out.type = PS_EVENT_RUMBLE;
			out.rumble_left = event->rumble.left;
			out.rumble_right = event->rumble.right;
			break;
		case CHIAKI_EVENT_QUIT:
			out.type = PS_EVENT_QUIT;
			out.quit_reason = (int32_t)event->quit.reason;
			out.quit_is_error = chiaki_quit_reason_is_error(event->quit.reason);
			out.quit_reason_string = chiaki_quit_reason_string(event->quit.reason);
			out.quit_detail = event->quit.reason_str;
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			out.type = PS_EVENT_TRIGGER_EFFECTS;
			out.trigger_type_left = event->trigger_effects.type_left;
			out.trigger_type_right = event->trigger_effects.type_right;
			memcpy(out.trigger_left, event->trigger_effects.left, sizeof(out.trigger_left));
			memcpy(out.trigger_right, event->trigger_effects.right, sizeof(out.trigger_right));
			break;
		case CHIAKI_EVENT_MOTION_RESET:
			out.type = PS_EVENT_MOTION_RESET;
			break;
		case CHIAKI_EVENT_LED_COLOR:
			out.type = PS_EVENT_LED_COLOR;
			memcpy(out.led, event->led_state, sizeof(out.led));
			break;
		case CHIAKI_EVENT_PLAYER_INDEX:
			out.type = PS_EVENT_PLAYER_INDEX;
			out.player_index = event->player_index;
			break;
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
			out.type = PS_EVENT_HAPTIC_INTENSITY;
			out.intensity = map_intensity(event->intensity);
			break;
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
			out.type = PS_EVENT_TRIGGER_INTENSITY;
			out.intensity = map_intensity(event->intensity);
			break;
		case CHIAKI_EVENT_VIDEO_FEC_FAILURE:
			out.type = PS_EVENT_VIDEO_FEC_FAILURE;
			break;
		default:
			// HOLEPUNCH / REGIST only occur for PSN (internet) sessions, which are not wired up yet.
			return;
	}
	s->cbs.event(&out, s->cbs.user);
}

PSSession *ps_session_create(const PSSessionConfig *config, const PSSessionCallbacks *callbacks, int32_t *err)
{
	ChiakiLog *log = core_log();
	PSSession *s = calloc(1, sizeof(PSSession));
	if(!s)
	{
		if(err)
			*err = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->cbs = *callbacks;
	s->host = strdup(config->host);
	if(!s->host)
	{
		free(s);
		if(err)
			*err = CHIAKI_ERR_MEMORY;
		return NULL;
	}

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = config->ps5;
	info.host = s->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->rp_key, sizeof(info.morning));
	info.video_profile.width = config->width;
	info.video_profile.height = config->height;
	info.video_profile.max_fps = config->max_fps;
	info.video_profile.bitrate = config->bitrate_kbps;
	info.video_profile.codec = config->ps5 ? (ChiakiCodec)config->codec : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = config->auto_downgrade;
	info.enable_keyboard = config->enable_keyboard;
	info.enable_dualsense = config->ps5 && config->enable_dualsense;
	info.audio_video_disabled = 0;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	memcpy(info.psn_account_id, config->psn_account_id, sizeof(info.psn_account_id));
	info.packet_loss_max = config->packet_loss_max;
	info.enable_idr_on_fec_failure = config->enable_idr_on_fec_failure;

	chiaki_opus_decoder_init(&s->opus_decoder, log);

	ChiakiErrorCode r = chiaki_session_init(&s->session, &info, log);
	if(err)
		*err = r;
	if(r != CHIAKI_ERR_SUCCESS)
	{
		chiaki_opus_decoder_fini(&s->opus_decoder);
		free(s->host);
		free(s);
		return NULL;
	}

	ChiakiCtrlDisplaySink display_sink;
	display_sink.user = s;
	display_sink.cantdisplay_cb = session_cant_display_cb;
	chiaki_session_ctrl_set_display_sink(&s->session, &display_sink);

	chiaki_opus_decoder_set_cb(&s->opus_decoder, session_audio_settings_cb, session_audio_frame_cb, s);
	ChiakiAudioSink audio_sink;
	chiaki_opus_decoder_get_sink(&s->opus_decoder, &audio_sink);
	chiaki_session_set_audio_sink(&s->session, &audio_sink);

	if(info.enable_dualsense)
	{
		ChiakiAudioSink haptics_sink;
		memset(&haptics_sink, 0, sizeof(haptics_sink));
		haptics_sink.user = s;
		haptics_sink.frame_cb = session_haptics_frame_cb;
		chiaki_session_set_haptics_sink(&s->session, &haptics_sink);
	}

	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);
	chiaki_session_set_event_cb(&s->session, session_event_cb, s);
	return s;
}

int32_t ps_session_start(PSSession *s)
{
	if(s->started)
		return CHIAKI_ERR_SUCCESS;
	ChiakiErrorCode r = chiaki_session_start(&s->session);
	if(r == CHIAKI_ERR_SUCCESS)
		s->started = true;
	return r;
}

int32_t ps_session_stop(PSSession *s)
{
	if(!s->started)
		return CHIAKI_ERR_SUCCESS;
	return chiaki_session_stop(&s->session);
}

void ps_session_destroy(PSSession *s)
{
	if(!s)
		return;
	if(s->started && !s->joined)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
		s->joined = true;
	}
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus_decoder);
	free(s->host);
	free(s);
}

int32_t ps_session_set_controller_state(PSSession *s, const PSControllerState *state)
{
	ChiakiControllerState cs;
	chiaki_controller_state_set_idle(&cs);
	cs.buttons = state->buttons;
	cs.l2_state = state->l2;
	cs.r2_state = state->r2;
	cs.left_x = state->left_x;
	cs.left_y = state->left_y;
	cs.right_x = state->right_x;
	cs.right_y = state->right_y;
	cs.touch_id_next = state->touch_id_next;
	cs.touches[0].x = state->touch0.x;
	cs.touches[0].y = state->touch0.y;
	cs.touches[0].id = state->touch0.id;
	cs.touches[1].x = state->touch1.x;
	cs.touches[1].y = state->touch1.y;
	cs.touches[1].id = state->touch1.id;
	cs.gyro_x = state->gyro_x;
	cs.gyro_y = state->gyro_y;
	cs.gyro_z = state->gyro_z;
	cs.accel_x = state->accel_x;
	cs.accel_y = state->accel_y;
	cs.accel_z = state->accel_z;
	cs.orient_x = state->orient_x;
	cs.orient_y = state->orient_y;
	cs.orient_z = state->orient_z;
	cs.orient_w = state->orient_w;
	return chiaki_session_set_controller_state(&s->session, &cs);
}

int32_t ps_session_set_login_pin(PSSession *s, const char *pin_digits)
{
	return chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin_digits, strlen(pin_digits));
}

int32_t ps_session_request_idr(PSSession *s)
{
	return chiaki_session_request_idr(&s->session);
}

int32_t ps_session_goto_bed(PSSession *s)
{
	return chiaki_session_goto_bed(&s->session);
}

int32_t ps_session_go_home(PSSession *s)
{
	return chiaki_session_go_home(&s->session);
}

int32_t ps_session_keyboard_set_text(PSSession *s, const char *text)
{
	return chiaki_session_keyboard_set_text(&s->session, text);
}

int32_t ps_session_keyboard_accept(PSSession *s)
{
	return chiaki_session_keyboard_accept(&s->session);
}

int32_t ps_session_keyboard_reject(PSSession *s)
{
	return chiaki_session_keyboard_reject(&s->session);
}

void ps_session_get_stats(PSSession *s, PSSessionStats *out)
{
	memset(out, 0, sizeof(*out));
	// Unsynchronised reads of values the core updates on its own threads: fine for a stats overlay.
	out->measured_bitrate = s->session.stream_connection.measured_bitrate * 1000000.0;
	out->packet_loss = s->session.stream_connection.congestion_control.packet_loss;
	out->rtt_us = s->session.rtt_us;
	out->mtu_in = s->session.mtu_in;
	out->mtu_out = s->session.mtu_out;
}
