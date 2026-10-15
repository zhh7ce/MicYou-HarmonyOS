# SPDX-License-Identifier: GPL-3.0-or-later
#
# MicYou — Turns your phone into a high-quality PC microphone.
# Copyright (C) 2026 zhh7ce <https://github.com/zhh7ce/MicYou-HarmonyOS>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

# MicYou HarmonyOS client — napi bridge around the vendored libopus sources.
cmake_minimum_required(VERSION 3.16)
project(mcyopus LANGUAGES C CXX)

# Encoder options live here (not in externalNativeOptions.arguments) so the
# gitignored build-profile never changes what gets compiled.
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)

add_subdirectory(opus)

add_library(mcyopus SHARED napi_init.cpp)
target_link_libraries(mcyopus PRIVATE opus libace_napi.z.so libhilog_ndk.z.so)
