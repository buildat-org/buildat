# WAMR 2.4.5 (https://github.com/bytecodealliance/wasm-micro-runtime, the
# release's source tarball WAMR-2.4.5.tar.gz from the tag, sha256
# 1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b),
# Apache 2.0 with LLVM exception (LICENSE). [CLIENT_WASM] step 4: the
# native client runs a module in its fast interpreter before the wasm2c
# compile is done, and where there is no compiler.
# Only what that uses is kept: the fast interpreter and its loader, the
# runtime common to all engines, the memory allocator, and the platform
# layer for Linux. No AOT, JIT, WASI, libc, threads, SIMD, GC, multi-module,
# reference types, debugger or C API (the AOT headers stay, as the common
# code includes them). Updated by copying the same files out of a newer
# release; the files are as released, this CMakeLists.txt and c_api_stub.c
# are buildat's.
cmake_minimum_required(VERSION 3.10)

set(W ${CMAKE_CURRENT_SOURCE_DIR}/core)
add_library(wamr STATIC
	${W}/iwasm/interpreter/wasm_interp_fast.c
	${W}/iwasm/interpreter/wasm_loader.c
	${W}/iwasm/interpreter/wasm_runtime.c
	${W}/iwasm/common/wasm_blocking_op.c
	${W}/iwasm/common/wasm_exec_env.c
	${W}/iwasm/common/wasm_loader_common.c
	${W}/iwasm/common/wasm_memory.c
	${W}/iwasm/common/wasm_native.c
	${W}/iwasm/common/wasm_runtime_common.c
	${W}/iwasm/common/arch/invokeNative_general.c
	${W}/shared/mem-alloc/mem_alloc.c
	${W}/shared/mem-alloc/ems/ems_alloc.c
	${W}/shared/mem-alloc/ems/ems_gc.c
	${W}/shared/mem-alloc/ems/ems_hmu.c
	${W}/shared/mem-alloc/ems/ems_kfc.c
	${W}/shared/platform/linux/platform_init.c
	${W}/shared/platform/common/posix/posix_blocking_op.c
	${W}/shared/platform/common/posix/posix_malloc.c
	${W}/shared/platform/common/posix/posix_memmap.c
	${W}/shared/platform/common/posix/posix_sleep.c
	${W}/shared/platform/common/posix/posix_thread.c
	${W}/shared/platform/common/posix/posix_time.c
	${W}/shared/utils/bh_assert.c
	${W}/shared/utils/bh_bitmap.c
	${W}/shared/utils/bh_common.c
	${W}/shared/utils/bh_hashmap.c
	${W}/shared/utils/bh_leb128.c
	${W}/shared/utils/bh_list.c
	${W}/shared/utils/bh_log.c
	${W}/shared/utils/bh_queue.c
	${W}/shared/utils/bh_vector.c
	${W}/shared/utils/runtime_timer.c
	# buildat's: the C API left out (wasm_c_api.c)
	c_api_stub.c
)
target_include_directories(wamr PUBLIC ${W}/iwasm/include)
target_include_directories(wamr PRIVATE
	${W}
	${W}/iwasm/common
	${W}/iwasm/interpreter
	${W}/shared/utils
	${W}/shared/mem-alloc
	${W}/shared/platform/include
	${W}/shared/platform/linux)
# Everything not named here is off by config.h's defaults; these are the
# ones that default on, or that are named for the record.
# - The memory's bounds checked by the interpreter's own code on every
#   access (WASM_DISABLE_HW_BOUND_CHECK): no guard pages and no signal
#   handler of WAMR's beside the client's (wasm.cpp's), no configurable
#   switch to turn the checks off.
# - The memory as the module declares it (no shrinking to one big page
#   by WAMR's guess of the heap's base).
target_compile_definitions(wamr PRIVATE
	BH_PLATFORM_LINUX
	BUILD_TARGET_X86_64
	BH_MALLOC=wasm_runtime_malloc
	BH_FREE=wasm_runtime_free
	_GNU_SOURCE
	WASM_HAVE_MREMAP=1
	WASM_ENABLE_INTERP=1
	WASM_ENABLE_FAST_INTERP=1
	WASM_ENABLE_LABELS_AS_VALUES=1
	WASM_ENABLE_MINI_LOADER=0
	WASM_ENABLE_AOT=0
	WASM_ENABLE_JIT=0
	WASM_ENABLE_FAST_JIT=0
	WASM_ENABLE_LAZY_JIT=0
	WASM_ENABLE_WAMR_COMPILER=0
	WASM_ENABLE_LIBC_BUILTIN=0
	WASM_ENABLE_LIBC_WASI=0
	WASM_ENABLE_LIB_PTHREAD=0
	WASM_ENABLE_LIB_WASI_THREADS=0
	WASM_ENABLE_THREAD_MGR=0
	WASM_ENABLE_SHARED_MEMORY=0
	WASM_ENABLE_SIMD=0
	WASM_ENABLE_MULTI_MODULE=0
	WASM_ENABLE_MULTI_MEMORY=0
	WASM_ENABLE_MEMORY64=0
	WASM_ENABLE_REF_TYPES=0
	WASM_ENABLE_GC=0
	WASM_ENABLE_EXCE_HANDLING=0
	WASM_ENABLE_TAIL_CALL=0
	WASM_ENABLE_BULK_MEMORY=1
	WASM_ENABLE_DEBUG_INTERP=0
	WASM_ENABLE_LOAD_CUSTOM_SECTION=0
	WASM_ENABLE_CUSTOM_NAME_SECTION=0
	WASM_ENABLE_DUMP_CALL_STACK=0
	WASM_ENABLE_PERF_PROFILING=0
	WASM_ENABLE_MEMORY_PROFILING=0
	WASM_ENABLE_SHARED_HEAP=0
	WASM_ENABLE_SHRUNK_MEMORY=0
	WASM_ENABLE_INSTRUCTION_METERING=0
	WASM_ENABLE_SPEC_TEST=0
	WASM_ENABLE_APP_FRAMEWORK=0
	WASM_DISABLE_HW_BOUND_CHECK=1
	WASM_DISABLE_STACK_HW_BOUND_CHECK=1
	WASM_DISABLE_WAKEUP_BLOCKING_OP=1
	WASM_CONFIGURABLE_BOUNDS_CHECKS=0
	BH_DEBUG=0
)
target_compile_options(wamr PRIVATE -O2 -w -std=gnu99)
set_target_properties(wamr PROPERTIES POSITION_INDEPENDENT_CODE ON)
