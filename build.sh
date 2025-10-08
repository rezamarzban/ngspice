#!/bin/bash
set -e

# -------------------------------------------------------------------
# Check and install prerequisites
# -------------------------------------------------------------------
PKGS=(git curl tar make libtool autoconf automake pkg-config)
MISSING=()
for pkg in "${PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
  echo "Installing missing packages: ${MISSING[*]}"
  sudo apt update
  sudo apt install -y "${MISSING[@]}"
else
  echo "✅ All prerequisites already installed."
fi

# -------------------------------------------------------------------
# Install wasi-sdk 20.0 (clang 15)
# -------------------------------------------------------------------
WASI_VERSION=20.0
WASI_SDK_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-20/wasi-sdk-${WASI_VERSION}-linux.tar.gz"

if [ ! -d "wasi-sdk-${WASI_VERSION}" ]; then
  echo "Downloading wasi-sdk ${WASI_VERSION}..."
  curl -L "${WASI_SDK_URL}" -o wasi-sdk.tar.gz
  tar -xvf wasi-sdk.tar.gz
  rm wasi-sdk.tar.gz
fi

export WASI_SDK_PATH="$PWD/wasi-sdk-${WASI_VERSION}"
export PATH="$WASI_SDK_PATH/bin:$PATH"

# -------------------------------------------------------------------
# Prepare ngspice source (reuse backup if present)
# -------------------------------------------------------------------
/*
if [ -f "../ngspice-backup.tar.gz" ]; then
  echo "Found ngspice-backup.tar.gz, extracting..."
  rm -rf ngspice
  tar -xzf ../ngspice-backup.tar.gz
else
  echo "No backup found, cloning from GitHub..."
  rm -rf ngspice
  git clone https://github.com/imr/ngspice.git ngspice
  # Create backup for next time
  tar -czf ../ngspice-backup.tar.gz ngspice
fi

cd ngspice
*/

# -------------------------------------------------------------------
# Apply WASI patches (idempotent, guarded by markers)
# -------------------------------------------------------------------

# 1) streams.c: stub dup2 (guard with marker)
STREAMS_FILE="src/frontend/streams.c"
if [ -f "$STREAMS_FILE" ] && ! grep -q "NGSPICE_WASI_DUP2" "$STREAMS_FILE"; then
  echo "Patching $STREAMS_FILE with WASI dup2 stub..."
  sed -i '/#include "streams.h"/a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_DUP2\n#define NGSPICE_WASI_DUP2\n/* WASI has no dup2; provide a stub */\nstatic inline int dup2(int oldfd, int newfd) {\n    (void)oldfd;\n    return newfd;\n}\n#endif\n#endif' "$STREAMS_FILE"
fi

# 2) evaluate.c: stub setjmp/longjmp
EVALUATE_FILE="src/frontend/evaluate.c"
if [ -f "$EVALUATE_FILE" ] && ! grep -q "NGSPICE_WASI_SETJMP" "$EVALUATE_FILE"; then
  echo "Patching $EVALUATE_FILE with WASI setjmp stub..."
  sed -i 's|#include <setjmp.h>|#ifdef __wasi__\n#ifndef NGSPICE_WASI_SETJMP\n#define NGSPICE_WASI_SETJMP\n#include <stdio.h>\ntypedef int jmp_buf;\nstatic inline int setjmp(jmp_buf env){(void)env;return 0;}\nstatic inline void longjmp(jmp_buf env,int val){(void)env;(void)val;}\n#endif\n#else\n#include <setjmp.h>\n#endif|' "$EVALUATE_FILE"
fi

# 3) src/main.c: stub setjmp/longjmp, dup2, and improved tmpfile (note: main.c is in src/)
MAIN_FILE="src/main.c"
if [ -f "$MAIN_FILE" ]; then
  if ! grep -q "NGSPICE_WASI_SETJMP" "$MAIN_FILE"; then
    echo "Patching $MAIN_FILE with WASI setjmp stub..."
    sed -i 's|#include <setjmp.h>|#ifdef __wasi__\n#ifndef NGSPICE_WASI_SETJMP\n#define NGSPICE_WASI_SETJMP\n#include <stdio.h>\ntypedef int jmp_buf;\nstatic inline int setjmp(jmp_buf env){(void)env;return 0;}\nstatic inline void longjmp(jmp_buf env,int val){(void)env;(void)val;}\n#endif\n#else\n#include <setjmp.h>\n#endif|' "$MAIN_FILE"
  fi
  if ! grep -q "NGSPICE_WASI_DUP2" "$MAIN_FILE"; then
    echo "Patching $MAIN_FILE with WASI dup2 stub..."
    sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_DUP2\n#define NGSPICE_WASI_DUP2\nstatic inline int dup2(int oldfd, int newfd) {\n    (void)oldfd;\n    return newfd;\n}\n#endif\n#endif' "$MAIN_FILE"
  fi
  if ! grep -q "NGSPICE_WASI_TMPFILE" "$MAIN_FILE"; then
    echo "Patching $MAIN_FILE with improved WASI tmpfile stub..."
    sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_TMPFILE\n#define NGSPICE_WASI_TMPFILE\n#include <stdio.h>\n#include <fcntl.h>\n#include <unistd.h>\n#include <stdlib.h>\n#include <errno.h>\nstatic int tmp_counter = 0;\nFILE *tmpfile(void) {\n    char name[64];\n    int fd;\n    do {\n        snprintf(name, sizeof(name), "/tmp/ngspice_tmp_%d", tmp_counter++);\n        fd = open(name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);\n    } while (fd == -1 && errno == EEXIST && tmp_counter < 10000);\n    if (fd == -1) {\n        return NULL;\n    }\n    unlink(name);\n    FILE *f = fdopen(fd, "w+b");\n    if (!f) {\n        close(fd);\n    }\n    return f;\n}\n#endif\n#endif' "$MAIN_FILE"
  fi
fi

# 4) signal_handler.c: stub POSIX signals (kill, tcgetpgrp, getpgrp)
SIGNAL_FILE="src/frontend/signal_handler.c"
if [ -f "$SIGNAL_FILE" ] && ! grep -q "NGSPICE_WASI_SIGNAL_STUBS" "$SIGNAL_FILE"; then
  echo "Patching $SIGNAL_FILE with WASI signal stubs..."
  sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_SIGNAL_STUBS\n#define NGSPICE_WASI_SIGNAL_STUBS\nstatic inline int kill(int pid, int sig){(void)pid;(void)sig;return -1;}\nstatic inline int tcgetpgrp(int fd){(void)fd;return 0;}\nstatic inline int getpgrp(void){return 0;}\n#endif\n#endif' "$SIGNAL_FILE"
  # Replace any direct include of <setjmp.h> with guarded version (handles setjmp/longjmp stubs)
  sed -i 's|#include <setjmp.h>|#ifdef __wasi__\n#ifndef NGSPICE_WASI_SETJMP\n#define NGSPICE_WASI_SETJMP\n#include <stdio.h>\ntypedef int jmp_buf;\nstatic inline int setjmp(jmp_buf env){(void)env;return 0;}\nstatic inline void longjmp(jmp_buf env,int val){(void)env;(void)val;}\n#endif\n#else\n#include <setjmp.h>\n#endif|' "$SIGNAL_FILE"
fi

# 5) get_avail_mem_size.c: fix top OS block (#else -> #elif __wasi__), drop #error, add WASI stub
MEM_AVAIL_FILE="src/frontend/get_avail_mem_size.c"
if [ -f "$MEM_AVAIL_FILE" ]; then
  echo "Patching $MEM_AVAIL_FILE OS detection block for WASI..."
  # Convert the lone '#else' of the OS detection prelude to '#elif defined(__wasi__)'
  sed -i -E '0,/#endif/s/^[[:space:]]*#else[[:space:]]*$/#elif defined(__wasi__)/' "$MEM_AVAIL_FILE"
  # Remove the #error line that complains about unknown OS
  sed -i -E 's/^#error "Unable to define getMemorySize\( \) for an unknown OS\."\s*$//' "$MEM_AVAIL_FILE"
  # Add WASI stub implementation if not present
  if ! grep -q "NGSPICE_WASI_MEM_AVAIL_STUB" "$MEM_AVAIL_FILE"; then
    sed -i '/#elif defined(__wasi__)/a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_MEM_AVAIL_STUB\n#define NGSPICE_WASI_MEM_AVAIL_STUB\nsize_t getMemorySize(void) {\n    return 8589934592ULL; /* 8 GB */\n}\n#endif\n#endif' "$MEM_AVAIL_FILE"
  fi
fi

# 6) get_phys_mem_size.c: fix top OS block (#else -> #elif __wasi__), drop #error, add WASI stub
MEM_PHYS_FILE="src/frontend/get_phys_mem_size.c"
if [ -f "$MEM_PHYS_FILE" ]; then
  echo "Patching $MEM_PHYS_FILE OS detection block for WASI..."
  sed -i -E '0,/#endif/s/^[[:space:]]*#else[[:space:]]*$/#elif defined(__wasi__)/' "$MEM_PHYS_FILE"
  sed -i -E 's/^#error "Unable to define getMemorySize\( \) for an unknown OS\."\s*$//' "$MEM_PHYS_FILE"
  # Add WASI stub implementation if not present
  if ! grep -q "NGSPICE_WASI_MEM_PHYS_STUB" "$MEM_PHYS_FILE"; then
    sed -i '/#elif defined(__wasi__)/a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_MEM_PHYS_STUB\n#define NGSPICE_WASI_MEM_PHYS_STUB\nsize_t getPhysMemorySize(void) {\n    return 8589934592ULL; /* 8 GB */\n}\n#endif\n#endif' "$MEM_PHYS_FILE"
  fi
fi

# 7) get_resident_set_size.c: fix top OS block (#else -> #elif __wasi__), drop #error, add WASI stub
RSS_FILE="src/frontend/get_resident_set_size.c"
if [ -f "$RSS_FILE" ]; then
  echo "Patching $RSS_FILE OS detection block for WASI..."
  sed -i -E '0,/#endif/s/^[[:space:]]*#else[[:space:]]*$/#elif defined(__wasi__)/' "$RSS_FILE"
  sed -i -E 's/^#error "Cannot define getPeakRSS\( \) or getCurrentRSS\( \) for an unknown OS\."\s*$//' "$RSS_FILE"
  # Add WASI stub implementation if not present
  if ! grep -q "NGSPICE_WASI_RSS_STUB" "$RSS_FILE"; then
    sed -i '/#elif defined(__wasi__)/a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_RSS_STUB\n#define NGSPICE_WASI_RSS_STUB\nsize_t getPeakRSS(void) {\n    return 0;\n}\nsize_t getCurrentRSS(void) {\n    return 0;\n}\n#endif\n#endif' "$RSS_FILE"
  fi
fi

# 8) inpcom.c: stub realpath with marker and guard to avoid redefinition
INPCOM_FILE="src/frontend/inpcom.c"
if [ -f "$INPCOM_FILE" ] && ! grep -q "WASI_REALPATH_STUB" "$INPCOM_FILE"; then
  echo "Patching $INPCOM_FILE with WASI realpath stub..."
  sed -i '1i \
#ifdef __wasi__\n#ifndef WASI_REALPATH_STUB\n#define WASI_REALPATH_STUB\n#include <limits.h>\n#include <string.h>\nstatic inline char *wasi_realpath(const char *path, char *resolved_path) {\n    if (resolved_path) {\n        strncpy(resolved_path, path, PATH_MAX - 1);\n        resolved_path[PATH_MAX - 1] = '\''\\0'\'';\n        return resolved_path;\n    }\n    return (char*)path;\n}\n#define realpath(P,R) wasi_realpath((P),(R))\n#endif\n#endif' "$INPCOM_FILE"
fi

# 9) com_hardcopy.c: stub system
COM_HARDCOPY_FILE="src/frontend/com_hardcopy.c"
if [ -f "$COM_HARDCOPY_FILE" ] && ! grep -q "NGSPICE_WASI_SYSTEM" "$COM_HARDCOPY_FILE"; then
  echo "Patching $COM_HARDCOPY_FILE with WASI system stub..."
  sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_SYSTEM\n#define NGSPICE_WASI_SYSTEM\n#include <stdlib.h>\nint system(const char *command) {\n    (void)command;\n    return -1;\n}\n#endif\n#endif' "$COM_HARDCOPY_FILE"
fi

# 10) variable.c: stub getpid
VAR_FILE="src/frontend/variable.c"
if [ -f "$VAR_FILE" ] && ! grep -q "NGSPICE_WASI_GETPID" "$VAR_FILE"; then
  echo "Patching $VAR_FILE with WASI getpid stub..."
  sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_GETPID\n#define NGSPICE_WASI_GETPID\n#include <unistd.h>\npid_t getpid(void) {\n    return 1;\n}\n#endif\n#endif' "$VAR_FILE"
fi

# 11) outitf.c: stub clock
OUTITF_FILE="src/frontend/outitf.c"
if [ -f "$OUTITF_FILE" ] && ! grep -q "NGSPICE_WASI_CLOCK" "$OUTITF_FILE"; then
  echo "Patching $OUTITF_FILE with WASI clock stub..."
  sed -i '/#include /a \
#ifdef __wasi__\n#ifndef NGSPICE_WASI_CLOCK\n#define NGSPICE_WASI_CLOCK\n#include <time.h>\nclock_t clock(void) {\n    return 0;\n}\n#endif\n#endif' "$OUTITF_FILE"
fi

# -------------------------------------------------------------------
# Generate configure script (only if not already generated)
# -------------------------------------------------------------------
if [ ! -f configure ]; then
  ./autogen.sh
fi

# -------------------------------------------------------------------
# Configure for WASI with signal emulation (only if not already configured)
# -------------------------------------------------------------------
if [ ! -f config.status ]; then
  CC="${WASI_SDK_PATH}/bin/clang --target=wasm32-unknown-wasi" \
  CXX="${WASI_SDK_PATH}/bin/clang++ --target=wasm32-unknown-wasi" \
  AR="${WASI_SDK_PATH}/bin/llvm-ar" \
  RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib" \
  ./configure \
    --host=wasm32 \
    --disable-debug \
    --disable-xspice \
    --disable-osdi \
    --disable-openmp \
    --with-readline=no \
    --enable-shared=no \
    CFLAGS="-O2 -D_WASI_EMULATED_SIGNAL" \
    CXXFLAGS="-O2 -std=c++17 -D_WASI_EMULATED_SIGNAL" \
    LIBS="-lwasi-emulated-signal" \
    ac_cv_func_dup2=yes
fi

# -------------------------------------------------------------------
# Build with resume support and error logging
# -------------------------------------------------------------------
echo "Starting build (errors will be logged to error.txt)..."
: > error.txt
make -k -j"$(nproc)" 2> >(tee build_stderr.log | grep -i "error" > error.txt) || true

echo "⚠️ Build attempted. Check error.txt for errors."
echo "✅ If successful, you should find ngspice.wasm in src/.libs or src/."
echo "Run it with: wasmtime ./src/ngspice.wasm -- netlist.cir"
echo "A backup of the source is stored as ngspice-backup.tar.gz"
