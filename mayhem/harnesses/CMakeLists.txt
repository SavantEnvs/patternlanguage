# mayhem/harnesses/CMakeLists.txt -- our OWN CMake project (never modifies upstream's
# CMakeLists.txt or fuzz/CMakeLists.txt) that pulls the PatternLanguage source tree in as a
# subdirectory so the fuzz harnesses can link against its real `libpl`/`libpl-gen` CMake
# targets -- exactly the way upstream's own fuzz/CMakeLists.txt does it, just from a
# directory we own. `EXCLUDE_FROM_ALL` on the upstream subdirectory means only the targets we
# actually depend on (libpl, libpl-gen, fmt::fmt-header-only) get configured/built; cli/tests
# stay off in this tree (they're built by mayhem/build.sh's separate ORACLE tree instead).
#
# Configure-time inputs (all passed by mayhem/build.sh via -D...):
#   PL_ROOT                path to the PatternLanguage repo root
#   MAYHEM_FUZZER_LINK_FLAGS   e.g. "-fsanitize=fuzzer" ($LIB_FUZZING_ENGINE) -- linked into
#                              the fuzz_pattern/fuzz_data executables only
#   MAYHEM_LSAN_OFF_SRC    path to lsan_off.cc (__lsan_is_turned_off hook), linked into every harness
#   STANDALONE_FUZZ_MAIN   path to the base image's StandaloneFuzzTargetMain.c -- compiled
#                           once as a C object and linked into the *-standalone executables
#                           INSTEAD of MAYHEM_FUZZER_LINK_FLAGS
# CMAKE_C_FLAGS/CMAKE_CXX_FLAGS carry $SANITIZER_FLAGS + $DEBUG_FLAGS from the command line
# (global CMake cache variables), so they apply uniformly to this project's own targets AND
# to the add_subdirectory'd upstream targets (libpl, libpl-gen, wolv::*) -- the fuzzed LIBRARY
# gets SanitizerCoverage + ASan/UBSan instrumentation, not just the harness translation unit.
cmake_minimum_required(VERSION 3.21)
project(mayhem_pl_harnesses CXX C)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# All harness binaries land in one predictable place regardless of the nested upstream
# project's own per-directory output layout (mayhem/build.sh reads them from here).
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

if(NOT DEFINED PL_ROOT)
    message(FATAL_ERROR "PL_ROOT must be set to the PatternLanguage repo root")
endif()

set(LIBPL_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(LIBPL_ENABLE_CLI OFF CACHE BOOL "" FORCE)
set(LIBPL_ENABLE_EXAMPLE OFF CACHE BOOL "" FORCE)
set(LIBPL_ENABLE_FUZZING OFF CACHE BOOL "" FORCE)
set(LIBPL_ENABLE_PRECOMPILED_HEADERS OFF CACHE BOOL "" FORCE)
set(LIBPL_WARNINGS_AS_ERRORS OFF CACHE BOOL "" FORCE)

add_subdirectory("${PL_ROOT}" "${CMAKE_BINARY_DIR}/upstream" EXCLUDE_FROM_ALL)

# The base image's run-once standalone driver, compiled as C (a C++ harness would otherwise
# mangle its LLVMFuzzerTestOneInput reference -- see docs/netnew-worker-prompt.md §6).
if(DEFINED STANDALONE_FUZZ_MAIN)
    add_library(mayhem_standalone_main OBJECT "${STANDALONE_FUZZ_MAIN}")
    set_source_files_properties("${STANDALONE_FUZZ_MAIN}" PROPERTIES LANGUAGE C)
endif()

if(NOT DEFINED MAYHEM_LSAN_OFF_SRC)
    message(FATAL_ERROR "MAYHEM_LSAN_OFF_SRC must point at mayhem/harnesses/lsan_off.cc")
endif()

foreach(harness IN ITEMS fuzz_pattern fuzz_data)
    add_executable(${harness} "${harness}.cpp" ${MAYHEM_LSAN_OFF_SRC})
    target_link_libraries(${harness} PRIVATE libpl libpl-gen fmt::fmt-header-only)
    target_include_directories(${harness} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    if(DEFINED MAYHEM_FUZZER_LINK_FLAGS)
        separate_arguments(_mayhem_fuzzer_link_flags UNIX_COMMAND "${MAYHEM_FUZZER_LINK_FLAGS}")
        target_link_options(${harness} PRIVATE ${_mayhem_fuzzer_link_flags})
    endif()

    if(DEFINED STANDALONE_FUZZ_MAIN)
        add_executable(${harness}-standalone "${harness}.cpp" ${MAYHEM_LSAN_OFF_SRC})
        target_link_libraries(${harness}-standalone PRIVATE libpl libpl-gen fmt::fmt-header-only mayhem_standalone_main)
        target_include_directories(${harness}-standalone PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
endforeach()
