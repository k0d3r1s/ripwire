#!/usr/bin/env bash
# cacherecordcheck.sh — independent v18 per-file record codec compatibility gate.
#
# The fixed sizes/SHA-256 values below were captured from the unmodified saveCache encoder at source
# commit 4fa7a75e7d767aeff1e666f04eda16f4bf4084c1 on a little-endian 64-bit host. The synthetic one-file
# corpus below contains every serialized fact family, embedded NUL bytes in every string-bearing family,
# maximum-width accepted health/model counters, and rich lexical values that exercise 1/2/4-byte TFs.
# Regenerate from that source commit (never from the refactored encoder under test):
#   git worktree add /tmp/ripwire-cache-v18-baseline 4fa7a75e7d767aeff1e666f04eda16f4bf4084c1
#   cmake -S /tmp/ripwire-cache-v18-baseline -B /tmp/ripwire-cache-v18-baseline/build
#   cmake --build /tmp/ripwire-cache-v18-baseline/build -j2
#   CACHE_RECORD_SOURCE_ROOT=/tmp/ripwire-cache-v18-baseline CACHE_RECORD_BASELINE=1 \
#     RIPWIRE_BIN=/tmp/ripwire-cache-v18-baseline/build/ripwire bash test/cacherecordcheck.sh
#
# The gate compiles this test-only driver in the ingest translation unit so the internal codec seam is
# exercised directly. It links against the same CMake objects and compiler flags as the selected binary.

set -u
SCRIPT_ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
ROOT="${CACHE_RECORD_SOURCE_ROOT:-$SCRIPT_ROOT}"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j2)"; exit 2; }
if command -v shasum >/dev/null 2>&1; then
    sha256_of(){ shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
    sha256_of(){ sha256sum "$1" | awk '{print $1}'; }
else
    echo "shasum or sha256sum required"; exit 2
fi

BUILD_DIR="$( cd "$( dirname "$BIN" )" && pwd )"
FLAGS_MK="$BUILD_DIR/CMakeFiles/ripwire.dir/flags.make"
LINK_TXT="$BUILD_DIR/CMakeFiles/ripwire.dir/link.txt"
[ -f "$FLAGS_MK" ] && [ -f "$LINK_TXT" ] || { echo "cannot find CMake flags/link under $BUILD_DIR"; exit 2; }

DRIVER="$TMP/cacherecord_unit.cpp"
cat >"$DRIVER" <<'CPPEOF'
#include <fstream>
#include <iostream>
#include "ingest.cpp"

namespace
{
struct Fixture
{
    std::vector<std::string> files{ std::string( "/fixture/record\0path.cpp", 24 ) };
    std::vector<std::uint64_t> fileHash{ 0xfedcba9876543210ull };
    std::vector<long long> fileSize{ 0x102030405060708ll };
    std::vector<long long> fileMtime{ 0x112233445566778ll };
    std::vector<long long> fileCtime{ 0x223344556677889ll };
    std::vector<rw::FileHealth> fileHealth{ rw::FileHealth{ 0xffffffffu, 0xfffffffeu, 0xfffffffdu, 0xfffffffcu } };
    std::vector<rw::RawDef> defs;
    std::vector<rw::RawRef> refs;
    std::vector<rw::Include> incs;
    std::vector<rw::RawBind> binds;
    std::vector<rw::BindingAlias> ffis;
    std::vector<rw::RouteDef> routeDefs;
    std::vector<rw::RawRouteUse> routeUses;
    std::vector<rw::ConstOpen> constOpens;

    Fixture()
    {
        rw::RawDef def;
        def.fileId = 0; def.line = 0xffffffffu; def.startByte = 0xfffffffeu; def.endByte = 0xfffffffdu;
        def.nameByte = 0xfffffffcu; def.bodyByte = 0xfffffffbu; def.cx = 0xfffffffau; def.ccx = 0xfffffff9u;
        def.loc = 0xfffffff8u; def.locals = 0xfffffff7u; def.ppAlt = 0xffffu; def.humps = 0xfffeu;
        def.deepLoc = 0xfffdu; def.ev = 0xfffcu; def.params = 0xffffu; def.maxNest = 0xffu;
        def.arityExact = 1; def.testScope = 1; def.kind = rw::SymKind::Method; def.lang = rw::Lang::Cpp;
        def.name = std::string( "def\0name", 8 ); def.scope = std::string( "scope\0name", 10 );
        for( std::size_t i = 0; i < def.evWhy.size(); ++i ) { def.evWhy[i] = std::uint8_t( 0xf0u + i ); }
        def.lex.dlWeighted = 0xffffffffu;
        def.lex.tokenHashes = { 0x0102030405060708ull, 0x1112131415161718ull, 0x2122232425262728ull };
        def.lex.tokenTfs = { 0xffu, 0xffffu, 0xffffffffu };
        defs.push_back( def );

        rw::RawRef ref;
        ref.fileId = 0; ref.startByte = 0xffffffffu; ref.line = 0xfffffffeu; ref.lang = rw::Lang::Ruby;
        ref.isInherit = true; ref.isDocLink = true; ref.isCompose = true; ref.role = rw::RefRole::Type;
        ref.recv = rw::RecvKind::FieldOfVar; ref.argCount = 0xffffu; ref.argCountKnown = true;
        ref.name = std::string( "ref\0name", 8 ); ref.qualifier = std::string( "qual\0", 5 );
        ref.recvVar = std::string( "recv\0var", 8 ); ref.fieldName = std::string( "field\0", 6 );
        ref.composeRel = std::string( "uses\0", 5 );
        refs.push_back( ref );

        rw::Include inc;
        inc.fileId = 0; inc.isAngle = true; inc.isLazy = true; inc.isSymbolic = true; inc.byte = 0xffffffffu;
        inc.target = std::string( "target\0name", 11 );
        incs.push_back( inc );

        rw::RawBind bind;
        bind.fileId = 0; bind.startByte = 0xffffffffu; bind.lang = rw::Lang::TypeScript; bind.kind = rw::LocalBindKind::JsImport;
        bind.spanStart = 0xfffffffeu; bind.spanEnd = 0xfffffffdu; bind.var = std::string( "var\0", 4 );
        bind.typeName = std::string( "type\0name", 9 ); bind.importedName = std::string( "import\0name", 11 );
        binds.push_back( bind );

        rw::BindingAlias ffi;
        ffi.fileId = 0; ffi.kind = rw::BindKind::ExternC; ffi.lowConf = true;
        ffi.aliasName = std::string( "alias\0", 6 ); ffi.targetName = std::string( "target\0", 7 ); ffi.targetScope = std::string( "scope\0", 6 );
        ffis.push_back( ffi );

        rw::RouteDef routeDef;
        routeDef.fileId = 0; routeDef.line = 0xffffffffu; routeDef.method = rw::HttpMethod::Delete;
        routeDef.path = std::string( "/route\0def", 10 ); routeDef.handlerName = std::string( "handler\0", 8 );
        routeDefs.push_back( routeDef );

        rw::RawRouteUse routeUse;
        routeUse.fileId = 0; routeUse.startByte = 0xffffffffu; routeUse.line = 0xfffffffeu; routeUse.method = rw::HttpMethod::Patch;
        routeUse.path = std::string( "/route\0use", 10 );
        routeUses.push_back( routeUse );

        rw::ConstOpen constOpen;
        constOpen.fileId = 0; constOpen.startByte = 0xffffffffu; constOpen.endByte = 0xfffffffeu; constOpen.namespaceOnly = true;
        constOpen.written = std::string( "Const\0Open", 10 );
        constOpens.push_back( constOpen );
    }
};

bool sameFacts( const Fixture& fixture, const std::vector<rw::RawDef>& defs, const std::vector<rw::RawRef>& refs,
                const std::vector<rw::Include>& incs, const std::vector<rw::RawBind>& binds,
                const std::vector<rw::BindingAlias>& ffis, const std::vector<rw::RouteDef>& routeDefs,
                const std::vector<rw::RawRouteUse>& routeUses, const std::vector<rw::ConstOpen>& constOpens,
                const rw::FileHealth& health, long long size, long long mtime, long long ctime, bool rich )
{
    if( defs.size() != 1 || refs.size() != 1 || incs.size() != 1 || binds.size() != 1 || ffis.size() != 1
        || routeDefs.size() != 1 || routeUses.size() != 1 || constOpens.size() != 1 )
    {
        return false;
    }
    const rw::RawDef& d = defs[0]; const rw::RawRef& r = refs[0];
    return d.line == 0xffffffffu && d.params == 0xffffu && d.maxNest == 0xffu
        && d.name == fixture.defs[0].name && d.scope == fixture.defs[0].scope
        && ( !rich || ( d.lex.dlWeighted == 0xffffffffu && d.lex.tokenHashes == fixture.defs[0].lex.tokenHashes
                         && d.lex.tokenTfs == fixture.defs[0].lex.tokenTfs ) )
        && r.startByte == 0xffffffffu && r.argCount == 0xffffu && r.name == fixture.refs[0].name
        && incs[0].target == fixture.incs[0].target && binds[0].importedName == fixture.binds[0].importedName
        && ffis[0].aliasName == fixture.ffis[0].aliasName && routeDefs[0].path == fixture.routeDefs[0].path
        && routeUses[0].path == fixture.routeUses[0].path && constOpens[0].written == fixture.constOpens[0].written
        && health.errNodes == 0xffffffffu && health.errBytes == 0xfffffffeu
        && health.fileBytes == 0xfffffffdu && health.wsBytes == 0xfffffffcu
        && size == fixture.fileSize[0] && mtime == fixture.fileMtime[0] && ctime == fixture.fileCtime[0];
}

bool writeBytes( const char* path, std::string_view bytes )
{
    std::ofstream out( path, std::ios::binary );
    out.write( bytes.data(), std::streamsize( bytes.size() ) );
    return bool( out );
}

#ifndef CACHE_RECORD_BASELINE_DRIVER
bool exercise( const char* path, bool rich )
{
    Fixture fixture;
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::CacheFileIndexes indexes = rw::buildCacheFileIndexes( fixture.files.size(), fixture.defs, fixture.refs, fixture.incs,
                                                                    fixture.binds, fixture.ffis, fixture.routeDefs,
                                                                    fixture.routeUses, fixture.constOpens );
    const rw::CacheEncodeInput input{ fixture.fileHash, fixture.fileSize, fixture.fileMtime, fixture.fileCtime, fixture.fileHealth,
                                      fixture.defs, fixture.refs, fixture.incs, fixture.binds, fixture.ffis, fixture.routeDefs,
                                      fixture.routeUses, fixture.constOpens, rich };
    const rw::EncodedCacheRecord encoded = rw::encodeCacheRecord( 0, keys, indexes, input );
    if( encoded.pathHash != keys.pathHashes[0] || encoded.contentHash != fixture.fileHash[0]
        || encoded.sum != rw::recordSum32( encoded.bytes ) || !writeBytes( path, encoded.bytes ) )
    {
        return false;
    }

    std::vector<rw::RawDef> defs; std::vector<rw::RawRef> refs; std::vector<rw::Include> incs;
    std::vector<rw::RawBind> binds; std::vector<rw::BindingAlias> ffis; std::vector<rw::RouteDef> routeDefs;
    std::vector<rw::RawRouteUse> routeUses; std::vector<rw::ConstOpen> constOpens; rw::FileHealth health;
    long long size = -1, mtime = -1, ctime = -1;
    const rw::CacheRecordExpectation expected{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, rich };
    rw::CacheDecodeOutput output{ defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime };
    if( !rw::decodeCacheRecord( encoded.bytes, expected, output )
        || !sameFacts( fixture, defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime, rich ) )
    {
        return false;
    }

    fixture.defs = defs; fixture.refs = refs; fixture.incs = incs; fixture.binds = binds; fixture.ffis = ffis;
    fixture.routeDefs = routeDefs; fixture.routeUses = routeUses; fixture.constOpens = constOpens; fixture.fileHealth[0] = health;
    fixture.fileSize[0] = size; fixture.fileMtime[0] = mtime; fixture.fileCtime[0] = ctime;
    const rw::CacheFileIndexes decodedIndexes = rw::buildCacheFileIndexes( 1, defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens );
    const rw::CacheEncodeInput decodedInput{ fixture.fileHash, fixture.fileSize, fixture.fileMtime, fixture.fileCtime, fixture.fileHealth,
                                             defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, rich };
    if( rw::encodeCacheRecord( 0, keys, decodedIndexes, decodedInput ).bytes != encoded.bytes )
    {
        return false;
    }

    rw::CacheRecordExpectation wrong = expected;
    wrong.relativePath = "other.cpp";
    if( rw::decodeCacheRecord( encoded.bytes, wrong, output ) ) { return false; }
    wrong = expected; ++wrong.pathHash;
    if( rw::decodeCacheRecord( encoded.bytes, wrong, output ) ) { return false; }
    wrong = expected; ++wrong.contentHash;
    if( rw::decodeCacheRecord( encoded.bytes, wrong, output ) ) { return false; }
    wrong = expected; ++wrong.sum;
    if( rw::decodeCacheRecord( encoded.bytes, wrong, output ) ) { return false; }
    std::string trailing = encoded.bytes; trailing.push_back( '\0' );
    wrong = expected; wrong.sum = rw::recordSum32( trailing );
    if( rw::decodeCacheRecord( trailing, wrong, output ) ) { return false; }
    return true;
}
#else
bool exerciseLegacySaveLoop( const char* path, bool rich )
{
    Fixture fixture;
    const std::string cachePath = std::string( path ) + ".cache";
    rw::saveCache( cachePath, "/fixture", fixture.files, fixture.fileHash, fixture.fileSize, fixture.fileMtime,
                   fixture.fileCtime, fixture.fileHealth, fixture.defs, fixture.refs, fixture.incs, fixture.binds,
                   fixture.ffis, fixture.routeDefs, fixture.routeUses, fixture.constOpens, rich );
    rw::CacheFrame frame = rw::openCacheFrame( cachePath, rich );
    if( frame.entries.size() != 1 )
    {
        return false;
    }
    const rw::CacheEntry& entry = frame.entries[0];
    std::string record( entry.recLength, '\0' );
    return rw::preadExact( frame.blob.fd, record.data(), record.size(), entry.recOffset ) && writeBytes( path, record );
}
#endif
}

int main( int argc, char** argv )
{
    if( argc != 3 ) { return 2; }
    const rw::CacheIdentity id = rw::cacheIdentity();
    if( id.cacheVersion != rw::kCacheVersion || id.parserVerLean != rw::parserVerFor( false )
        || id.parserVerRich != rw::parserVerFor( true ) || id.artifactArch != rw::kArtifactArch )
    {
        return 3;
    }
#ifndef CACHE_RECORD_BASELINE_DRIVER
    const bool lean = exercise( argv[1], false );
    const bool rich = exercise( argv[2], true );
#else
    const bool lean = exerciseLegacySaveLoop( argv[1], false );
    const bool rich = exerciseLegacySaveLoop( argv[2], true );
#endif
    std::cout << ( lean && rich ? "UNIT ALL PASS\n" : "UNIT FAIL\n" );
    return lean && rich ? 0 : 1;
}
CPPEOF

CXX="$( awk 'NR==1{ print $1; exit }' "$LINK_TXT" )"
[ -n "$CXX" ] && command -v "$CXX" >/dev/null 2>&1 || CXX="$( command -v c++ || command -v clang++ )"
eval "CXX_FLAGS=(    $( grep -m1 '^CXX_FLAGS ='    "$FLAGS_MK" | sed 's/^CXX_FLAGS =//' ) )"
eval "CXX_DEFINES=(  $( grep -m1 '^CXX_DEFINES ='  "$FLAGS_MK" | sed 's/^CXX_DEFINES =//' ) )"
eval "CXX_INCLUDES=( $( grep -m1 '^CXX_INCLUDES =' "$FLAGS_MK" | sed 's/^CXX_INCLUDES =//' ) )"

LINK_BODY="$( sed -E 's#^[^ ]+ ##' "$LINK_TXT" )"
LINK_BODY="$( printf '%s' "$LINK_BODY" | sed -E 's#-o +ripwire##' )"
LINK_BODY="$( printf '%s' "$LINK_BODY" | sed -E 's#[^ " ]*ripwire.dir/src/(main|ingest)\.cpp\.o##g' )"
LINK_BODY="$( printf '%s' "$LINK_BODY" | tr -d '"' )"

OBJ="$TMP/unit.o"
if [ "${CACHE_RECORD_BASELINE:-0}" = 1 ]; then
    if ( cd "$BUILD_DIR" && "$CXX" "${CXX_FLAGS[@]}" "${CXX_DEFINES[@]}" "${CXX_INCLUDES[@]}" -DCACHE_RECORD_BASELINE_DRIVER=1 -c "$DRIVER" -o "$OBJ" ) 2>"$TMP/cc.err"; then
        ok "unit driver compiles against ripwire flags"
    else
        no "unit driver failed to compile"; sed -n '1,60p' "$TMP/cc.err"; exit 1
    fi
else
    if ( cd "$BUILD_DIR" && "$CXX" "${CXX_FLAGS[@]}" "${CXX_DEFINES[@]}" "${CXX_INCLUDES[@]}" -c "$DRIVER" -o "$OBJ" ) 2>"$TMP/cc.err"; then
        ok "unit driver compiles against ripwire flags"
    else
        no "unit driver failed to compile"; sed -n '1,60p' "$TMP/cc.err"; exit 1
    fi
fi

UNIT="$TMP/unit"
# shellcheck disable=SC2086
if ( cd "$BUILD_DIR" && "$CXX" "${CXX_FLAGS[@]}" "$OBJ" $LINK_BODY -o "$UNIT" ) 2>"$TMP/ld.err"; then
    ok "unit driver links against ripwire objects + tree-sitter"
else
    no "unit driver failed to link"; sed -n '1,60p' "$TMP/ld.err"; exit 1
fi

"$UNIT" "$TMP/lean.bin" "$TMP/rich.bin" >"$TMP/unit.out" 2>"$TMP/unit.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^UNIT ALL PASS$' "$TMP/unit.out"; then
    if [ "${CACHE_RECORD_BASELINE:-0}" = 1 ]; then
        ok "legacy saveCache loop extracted the independent v18 record baseline"
    else
        ok "independent encode/decode round trip, validation guards, embedded NULs and maximum-width counts"
    fi
else
    no "unit driver failed (rc=$rc)"; cat "$TMP/unit.out" "$TMP/unit.err"
fi

ARCH_KEY="$( python3 - <<'PYEOF'
import struct, sys
print(("little" if sys.byteorder == "little" else "big") + str(struct.calcsize("P") * 8))
PYEOF
)"
case "$ARCH_KEY" in
    little64)
        LEAN_SIZE=447; LEAN_SHA=4dd495877c02be912f0424eda2ef441e9f31bf0b37f35e9602f3f860aed4bfc5
        RICH_SIZE=499; RICH_SHA=47f8105e4861ce9b0e08adf5450e6b8e884991d1aaefa34da8c7802c88d01fb1
        ;;
    *) no "no committed v18 baseline for architecture $ARCH_KEY"; LEAN_SIZE=0; LEAN_SHA=none; RICH_SIZE=0; RICH_SHA=none;;
esac

if [ "${CACHE_RECORD_BASELINE:-0}" = 1 ]; then
    printf 'little64 lean size=%s sha256=%s\n' "$( wc -c <"$TMP/lean.bin" | tr -d ' ' )" "$( sha256_of "$TMP/lean.bin" )"
    printf 'little64 rich size=%s sha256=%s\n' "$( wc -c <"$TMP/rich.bin" | tr -d ' ' )" "$( sha256_of "$TMP/rich.bin" )"
fi

ACTUAL_LEAN_SIZE="$( wc -c <"$TMP/lean.bin" | tr -d ' ' )"; ACTUAL_LEAN_SHA="$( sha256_of "$TMP/lean.bin" )"
ACTUAL_RICH_SIZE="$( wc -c <"$TMP/rich.bin" | tr -d ' ' )"; ACTUAL_RICH_SHA="$( sha256_of "$TMP/rich.bin" )"
if [ "$ACTUAL_LEAN_SIZE" = "$LEAN_SIZE" ] && [ "$ACTUAL_LEAN_SHA" = "$LEAN_SHA" ]; then
    ok "lean v18 record matches independent baseline ($LEAN_SIZE B, $LEAN_SHA)"
else
    no "lean v18 drift: got $ACTUAL_LEAN_SIZE B $ACTUAL_LEAN_SHA, expected $LEAN_SIZE B $LEAN_SHA"
fi
if [ "$ACTUAL_RICH_SIZE" = "$RICH_SIZE" ] && [ "$ACTUAL_RICH_SHA" = "$RICH_SHA" ]; then
    ok "rich v18 record matches independent baseline ($RICH_SIZE B, $RICH_SHA)"
else
    no "rich v18 drift: got $ACTUAL_RICH_SIZE B $ACTUAL_RICH_SHA, expected $RICH_SIZE B $RICH_SHA"
fi

if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "SOME CHECKS FAILED"; exit 1
fi
