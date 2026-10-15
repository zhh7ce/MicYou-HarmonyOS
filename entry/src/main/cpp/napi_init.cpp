/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * MicYou — Turns your phone into a high-quality PC microphone.
 * Copyright (C) 2026 zhh7ce <https://github.com/zhh7ce/MicYou-HarmonyOS>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <opus.h>
#include <vector>
#include <cstring>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3307
#undef LOG_TAG
#define LOG_TAG "MicYouOpus"

namespace {

struct Slot {
    OpusEncoder *enc;
    int32_t frameSamples; // rate * 20 / 1000, the only frame size this client encodes
    int32_t channels;
    bool live;
};

std::vector<Slot> g_slots;

bool IsOpusRate(int32_t rate) {
    return rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000;
}

napi_value CreateEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t rate = 0;
    int32_t channels = 0;
    napi_get_value_int32(env, args[0], &rate);
    napi_get_value_int32(env, args[1], &channels);
    if (!IsOpusRate(rate) || (channels != 1 && channels != 2)) {
        napi_throw_error(env, nullptr, "invalid opus encoder config");
        return nullptr;
    }
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(rate, channels, OPUS_APPLICATION_VOIP, &err);
    if (enc == nullptr) {
        napi_throw_error(env, nullptr, opus_strerror(err));
        return nullptr;
    }
    opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(enc, OPUS_SET_DTX(1));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(0));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    Slot slot;
    slot.enc = enc;
    slot.frameSamples = rate * 20 / 1000;
    slot.channels = channels;
    slot.live = true;
    g_slots.push_back(slot);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "createEncoder rate=%{public}d ch=%{public}d handle=%{public}d",
                 rate, channels, static_cast<int>(g_slots.size()));
    napi_value out = nullptr;
    napi_create_int32(env, static_cast<int32_t>(g_slots.size()), &out); // handle = 1-based index
    return out;
}

napi_value Encode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    napi_get_value_int32(env, args[0], &handle);
    if (handle < 1 || static_cast<size_t>(handle) > g_slots.size() || !g_slots[handle - 1].live) {
        napi_throw_error(env, nullptr, "bad opus handle");
        return nullptr;
    }
    Slot &slot = g_slots[handle - 1];
    bool isAb = false;
    napi_is_arraybuffer(env, args[1], &isAb);
    if (!isAb) {
        napi_throw_error(env, nullptr, "pcm must be an ArrayBuffer");
        return nullptr;
    }
    void *data = nullptr;
    size_t byteLen = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &byteLen);
    // The bridge contract: exactly one 20 ms S16LE frame for this encoder's channel count.
    const size_t want = static_cast<size_t>(slot.frameSamples) * 2u * static_cast<size_t>(slot.channels);
    if (byteLen != want) {
        napi_throw_error(env, nullptr, "bad opus input frame size");
        return nullptr;
    }
    unsigned char out[4000];
    int n = opus_encode(slot.enc, static_cast<opus_int16 *>(data), slot.frameSamples, out, sizeof(out));
    if (n < 0) {
        napi_throw_error(env, nullptr, opus_strerror(n));
        return nullptr;
    }
    napi_value buf = nullptr;
    void * backing = nullptr;
    napi_create_arraybuffer(env, static_cast<size_t>(n), &backing, &buf);
    memcpy(backing, out, static_cast<size_t>(n));
    return buf;
}

napi_value DestroyEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = 0;
    napi_get_value_int32(env, args[0], &handle);
    if (handle < 1 || static_cast<size_t>(handle) > g_slots.size()) {
        return nullptr; // destroy is forgiving: double-destroy on teardown is not a session error
    }
    Slot &slot = g_slots[handle - 1];
    if (slot.live) {
        opus_encoder_destroy(slot.enc);
        slot.enc = nullptr;
        slot.live = false;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "destroyEncoder handle=%{public}d", handle);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"createEncoder", nullptr, CreateEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encode", nullptr, Encode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyEncoder", nullptr, DestroyEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mcyopus",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterMcyopusModule() {
    napi_module_register(&g_module);
}
