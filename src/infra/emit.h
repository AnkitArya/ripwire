#pragma once

// emit.h — THE formatted-output emitter, and the ONE place the std::print-versus-std::format choice is made.
//
// WHY A CHOICE AT ALL. The house rule (CONTRIBUTING.md §3 "Output") is std::print; the tree is printf-family
// by history and converting it is byte-parity-fenced by test/printffmtparitycheck.sh. <print> arrives in
// libstdc++ 14 and, on libc++, only at a macOS 14+ deployment target — and libc++ defines __cpp_lib_print
// only when the target admits it (measured 2026-09-08 with Apple clang 21: defined at -mmacosx-version-min
// 14.0, absent at 13.0), so testing the FEATURE MACRO rather than the header's presence is what keeps a
// lower target compiling instead of failing on an unavailable symbol. Every toolchain therefore builds:
// std::print where the library has it, std::format rendered and written with std::fputs where it does not.
//
// WHY THE CHOICE IS DISCLOSED. A silent fallback would let a CI leg on gcc 13 read as "the std::print floor
// holds". kRipwireEmitter names the path that compiled in; --version prints it as emit= (gated by
// test/versioncheck.sh #6) and each CI leg asserts the value it is supposed to have (.github/workflows).
//
// CONTRACT PARITY. std::fputs reports a failed write by return value, which every emitting site here has
// always ignored; std::print reports it by THROWING std::system_error. The std::print arm catches that one
// exception so the two arms keep one contract — a write failure is silent on both, exactly as before the
// conversion, and never a std::terminate the fputs arm could not produce. (A closed pipe is SIGPIPE on
// both arms and reaches neither.) fmt is NOT vendored: the standard library has the feature, so a vendored
// copy would be a G3 regression.

#include <cstdio>
#include <format>
#include <system_error>
#include <utility>
#include <version>
#if __has_include( <print> )
#include <print>
#endif

namespace rw
{

#if defined( __cpp_lib_print ) && __cpp_lib_print >= 202207L

inline constexpr const char* kRipwireEmitter = "std::print";

template<class... A> inline void emitTo( std::FILE* stream, std::format_string<A...> f, A&&... a )
{
    try
    {
        std::print( stream, f, std::forward<A>( a )... );
    }
    catch( const std::system_error& )
    {
        // fputs's contract, kept: a failed write is silent (see the header comment).
    }
}

#else

inline constexpr const char* kRipwireEmitter = "std::format+fputs";

template<class... A> inline void emitTo( std::FILE* stream, std::format_string<A...> f, A&&... a )
{
    std::fputs( std::format( f, std::forward<A>( a )... ).c_str(), stream );
}

#endif

}   // namespace rw
