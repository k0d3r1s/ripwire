#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>

#include "ingest.cpp"

#include <array>
#include <bit>
#include <cstdint>
#include <fstream>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace
{

struct Fixture
{
    std::vector<std::string>          files{ std::string( "/fixture/record\0path.cpp", 24 ) };
    std::vector<std::uint64_t>        fileHash{ 0xfedcba9876543210ull };
    std::vector<long long>            fileSize{ 0x102030405060708ll };
    std::vector<long long>            fileMtime{ 0x112233445566778ll };
    std::vector<long long>            fileCtime{ 0x223344556677889ll };
    std::vector<rw::FileHealth>       fileHealth{ rw::FileHealth{ 0xffffffffu, 0xfffffffeu, 0xfffffffdu, 0xfffffffcu } };
    std::vector<rw::RawDef>           defs;
    std::vector<rw::RawRef>           refs;
    std::vector<rw::Include>          incs;
    std::vector<rw::RawBind>          binds;
    std::vector<rw::BindingAlias>     ffis;
    std::vector<rw::RouteDef>         routeDefs;
    std::vector<rw::RawRouteUse>      routeUses;
    std::vector<rw::ConstOpen>        constOpens;

    Fixture()
    {
        rw::RawDef def;
        def.fileId = 0; def.line = 0xffffffffu; def.startByte = 0xfffffffeu; def.endByte = 0xfffffffdu;
        def.nameByte = 0xfffffffcu; def.bodyByte = 0xfffffffbu; def.cx = 0xfffffffau; def.ccx = 0xfffffff9u;
        def.loc = 0xfffffff8u; def.locals = 0xfffffff7u; def.ppAlt = 0xffffu; def.humps = 0xfffeu;
        def.deepLoc = 0xfffdu; def.ev = 0xfffcu; def.params = 0xffffu; def.maxNest = 0xffu;
        def.arityExact = 1; def.testScope = 1; def.kind = rw::SymKind::Method; def.lang = rw::Lang::Cpp;
        def.name = std::string( "def\0name", 8 ); def.scope = std::string( "scope\0name", 10 );
        for( std::size_t i = 0; i < def.evWhy.size(); ++i )
        {
            def.evWhy[i] = std::uint8_t( 0xf0u + i );
        }
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

#if !defined( CACHE_RECORD_BASELINE_DRIVER )
rw::CacheEncodeInput inputFor( const Fixture& fixture, const bool rich )
{
    return { fixture.fileHash, fixture.fileSize, fixture.fileMtime, fixture.fileCtime, fixture.fileHealth,
             fixture.defs, fixture.refs, fixture.incs, fixture.binds, fixture.ffis, fixture.routeDefs,
             fixture.routeUses, fixture.constOpens, rich };
}

rw::EncodedCacheRecord encodeFixture( const Fixture& fixture, const bool rich )
{
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::CacheFileIndexes indexes = rw::buildCacheFileIndexes( fixture.files.size(), fixture.defs, fixture.refs, fixture.incs,
                                                                    fixture.binds, fixture.ffis, fixture.routeDefs,
                                                                    fixture.routeUses, fixture.constOpens );
    return rw::encodeCacheRecord( 0, keys, indexes, inputFor( fixture, rich ) );
}
#endif

bool writeBytes( const char* path, const std::string_view bytes )
{
    std::ofstream out( path, std::ios::binary );
    out.write( bytes.data(), std::streamsize( bytes.size() ) );
    return bool( out );
}

#if defined( CACHE_RECORD_BASELINE_DRIVER )
bool writeLegacyRecord( const char* path, const bool rich )
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
#else
bool writeCurrentRecord( const char* path, const bool rich )
{
    const rw::EncodedCacheRecord encoded = encodeFixture( Fixture{}, rich );
    return writeBytes( path, encoded.bytes );
}

struct DecodeDestination
{
    std::vector<rw::RawDef>       defs;
    std::vector<rw::RawRef>       refs;
    std::vector<rw::Include>      incs;
    std::vector<rw::RawBind>      binds;
    std::vector<rw::BindingAlias> ffis;
    std::vector<rw::RouteDef>     routeDefs;
    std::vector<rw::RawRouteUse>  routeUses;
    std::vector<rw::ConstOpen>    constOpens;
    rw::FileHealth                health{ 91, 92, 93, 94 };
    long long                    fileSize  = 95;
    long long                    fileMtime = 96;
    long long                    fileCtime = 97;

    DecodeDestination()
    {
        rw::RawDef def; def.line = 11; def.name = "keep-def"; defs.push_back( def );
        rw::RawRef ref; ref.line = 12; ref.name = "keep-ref"; refs.push_back( ref );
        rw::Include inc; inc.byte = 13; inc.target = "keep-inc"; incs.push_back( inc );
        rw::RawBind bind; bind.startByte = 14; bind.var = "keep-bind"; binds.push_back( bind );
        rw::BindingAlias ffi; ffi.lowConf = true; ffi.aliasName = "keep-ffi"; ffis.push_back( ffi );
        rw::RouteDef routeDef; routeDef.line = 15; routeDef.path = "keep-route-def"; routeDefs.push_back( routeDef );
        rw::RawRouteUse routeUse; routeUse.line = 16; routeUse.path = "keep-route-use"; routeUses.push_back( routeUse );
        rw::ConstOpen constOpen; constOpen.startByte = 17; constOpen.written = "keep-const-open"; constOpens.push_back( constOpen );
    }

    rw::CacheDecodeOutput output()
    {
        return { defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, fileSize, fileMtime, fileCtime };
    }

    bool unchanged() const
    {
        return defs.size() == 1 && defs[0].line == 11 && defs[0].name == "keep-def"
            && refs.size() == 1 && refs[0].line == 12 && refs[0].name == "keep-ref"
            && incs.size() == 1 && incs[0].byte == 13 && incs[0].target == "keep-inc"
            && binds.size() == 1 && binds[0].startByte == 14 && binds[0].var == "keep-bind"
            && ffis.size() == 1 && ffis[0].lowConf && ffis[0].aliasName == "keep-ffi"
            && routeDefs.size() == 1 && routeDefs[0].line == 15 && routeDefs[0].path == "keep-route-def"
            && routeUses.size() == 1 && routeUses[0].line == 16 && routeUses[0].path == "keep-route-use"
            && constOpens.size() == 1 && constOpens[0].startByte == 17 && constOpens[0].written == "keep-const-open"
            && health.errNodes == 91 && health.errBytes == 92 && health.fileBytes == 93 && health.wsBytes == 94
            && fileSize == 95 && fileMtime == 96 && fileCtime == 97;
    }
};

void checkRejectedTransactionally( const std::string_view record, const rw::CacheRecordExpectation& expected,
                                   rw::CacheDecodeScratch& scratch )
{
    DecodeDestination destination;
    rw::CacheDecodeOutput output = destination.output();
    CHECK_FALSE( rw::decodeCacheRecordWithScratch( record, expected, output, scratch ) );
    CHECK( destination.unchanged() );
}

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
    const rw::RawDef& expectedDef = fixture.defs[0];
    const rw::RawDef& def = defs[0];
    const bool defMatches = def.fileId == expectedDef.fileId && def.line == expectedDef.line && def.startByte == expectedDef.startByte
        && def.endByte == expectedDef.endByte && def.nameByte == expectedDef.nameByte && def.bodyByte == expectedDef.bodyByte
        && def.cx == expectedDef.cx && def.ccx == expectedDef.ccx && def.loc == expectedDef.loc && def.locals == expectedDef.locals
        && def.ppAlt == expectedDef.ppAlt && def.humps == expectedDef.humps && def.deepLoc == expectedDef.deepLoc && def.ev == expectedDef.ev
        && def.evWhy == expectedDef.evWhy && def.params == expectedDef.params && def.maxNest == expectedDef.maxNest
        && def.arityExact == expectedDef.arityExact && def.testScope == expectedDef.testScope && def.kind == expectedDef.kind
        && def.lang == expectedDef.lang && def.name == expectedDef.name && def.scope == expectedDef.scope
        && ( rich ? def.lex.dlWeighted == expectedDef.lex.dlWeighted && def.lex.tokenHashes == expectedDef.lex.tokenHashes
                          && def.lex.tokenTfs == expectedDef.lex.tokenTfs
                  : def.lex.dlWeighted == 0 && def.lex.tokenHashes.empty() && def.lex.tokenTfs.empty() );

    const rw::RawRef& expectedRef = fixture.refs[0];
    const rw::RawRef& ref = refs[0];
    const bool refMatches = ref.fileId == expectedRef.fileId && ref.startByte == expectedRef.startByte && ref.line == expectedRef.line
        && ref.lang == expectedRef.lang && ref.isInherit == expectedRef.isInherit && ref.isDocLink == expectedRef.isDocLink
        && ref.isCompose == expectedRef.isCompose && ref.role == expectedRef.role && ref.recv == expectedRef.recv
        && ref.argCount == expectedRef.argCount && ref.argCountKnown == expectedRef.argCountKnown && ref.name == expectedRef.name
        && ref.qualifier == expectedRef.qualifier && ref.recvVar == expectedRef.recvVar && ref.fieldName == expectedRef.fieldName
        && ref.composeRel == expectedRef.composeRel;

    const rw::Include& expectedInc = fixture.incs[0];
    const rw::RawBind& expectedBind = fixture.binds[0];
    const rw::BindingAlias& expectedFfi = fixture.ffis[0];
    const rw::RouteDef& expectedRouteDef = fixture.routeDefs[0];
    const rw::RawRouteUse& expectedRouteUse = fixture.routeUses[0];
    const rw::ConstOpen& expectedConstOpen = fixture.constOpens[0];
    return defMatches && refMatches
        && incs[0].fileId == expectedInc.fileId && incs[0].isAngle == expectedInc.isAngle && incs[0].isLazy == expectedInc.isLazy
        && incs[0].isSymbolic == expectedInc.isSymbolic && incs[0].byte == expectedInc.byte && incs[0].target == expectedInc.target
        && binds[0].fileId == expectedBind.fileId && binds[0].startByte == expectedBind.startByte && binds[0].lang == expectedBind.lang
        && binds[0].kind == expectedBind.kind && binds[0].spanStart == expectedBind.spanStart && binds[0].spanEnd == expectedBind.spanEnd
        && binds[0].var == expectedBind.var && binds[0].typeName == expectedBind.typeName
        && binds[0].importedName == expectedBind.importedName
        && ffis[0].fileId == expectedFfi.fileId && ffis[0].kind == expectedFfi.kind && ffis[0].lowConf == expectedFfi.lowConf
        && ffis[0].aliasName == expectedFfi.aliasName && ffis[0].targetName == expectedFfi.targetName
        && ffis[0].targetScope == expectedFfi.targetScope
        && routeDefs[0].fileId == expectedRouteDef.fileId && routeDefs[0].line == expectedRouteDef.line
        && routeDefs[0].method == expectedRouteDef.method && routeDefs[0].path == expectedRouteDef.path
        && routeDefs[0].handlerName == expectedRouteDef.handlerName
        && routeUses[0].fileId == expectedRouteUse.fileId && routeUses[0].startByte == expectedRouteUse.startByte
        && routeUses[0].line == expectedRouteUse.line && routeUses[0].method == expectedRouteUse.method
        && routeUses[0].path == expectedRouteUse.path
        && constOpens[0].fileId == expectedConstOpen.fileId && constOpens[0].startByte == expectedConstOpen.startByte
        && constOpens[0].endByte == expectedConstOpen.endByte && constOpens[0].namespaceOnly == expectedConstOpen.namespaceOnly
        && constOpens[0].written == expectedConstOpen.written
        && health.errNodes == fixture.fileHealth[0].errNodes && health.errBytes == fixture.fileHealth[0].errBytes
        && health.fileBytes == fixture.fileHealth[0].fileBytes && health.wsBytes == fixture.fileHealth[0].wsBytes
        && size == fixture.fileSize[0] && mtime == fixture.fileMtime[0] && ctime == fixture.fileCtime[0];
}

void checkComprehensiveRoundTrip( const bool rich )
{
    Fixture fixture;
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, rich );
    std::vector<rw::RawDef> defs; std::vector<rw::RawRef> refs; std::vector<rw::Include> incs;
    std::vector<rw::RawBind> binds; std::vector<rw::BindingAlias> ffis; std::vector<rw::RouteDef> routeDefs;
    std::vector<rw::RawRouteUse> routeUses; std::vector<rw::ConstOpen> constOpens; rw::FileHealth health;
    long long size = -1, mtime = -1, ctime = -1;
    rw::CacheDecodeOutput output{ defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime };
    const rw::CacheRecordExpectation expected{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, rich };
    REQUIRE( rw::decodeCacheRecord( encoded.bytes, expected, output ) );
    CHECK( sameFacts( fixture, defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime, rich ) );

    fixture.defs = defs; fixture.refs = refs; fixture.incs = incs; fixture.binds = binds; fixture.ffis = ffis;
    fixture.routeDefs = routeDefs; fixture.routeUses = routeUses; fixture.constOpens = constOpens; fixture.fileHealth[0] = health;
    fixture.fileSize[0] = size; fixture.fileMtime[0] = mtime; fixture.fileCtime[0] = ctime;
    CHECK( encodeFixture( fixture, rich ).bytes == encoded.bytes );
}

void replaceU32( std::string& bytes, const std::size_t offset, const std::uint32_t value )
{
    REQUIRE( offset + sizeof( value ) <= bytes.size() );
    std::memcpy( bytes.data() + offset, &value, sizeof( value ) );
}

void checkSerializedCountMutations()
{
    Fixture fixture;
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, true );
    const rw::CacheRecordExpectation valid{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, true };
    rw::ByteR reader{ encoded.bytes.data(), encoded.bytes.data() + encoded.bytes.size() };
    (void)reader.view();
    for( std::size_t i = 0; i < 4; ++i ) { (void)reader.u64(); }
    for( std::size_t i = 0; i < 4; ++i ) { (void)reader.u32(); }

    std::vector<std::size_t> countOffsets;
    const std::size_t dictCountOffset = std::size_t( reader.p - encoded.bytes.data() );
    const std::uint32_t dictCount = reader.u32();
    std::vector<std::uint64_t> fileDict( dictCount );
    REQUIRE( reader.rawInto( fileDict.data(), fileDict.size() * sizeof( std::uint64_t ) ) );

    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 );
    rw::ByteR defProbe = reader;
    for( std::size_t i = 0; i < 14; ++i ) { (void)defProbe.u32(); }
    for( std::size_t i = 0; i < 5; ++i ) { (void)defProbe.u8(); }
    (void)defProbe.view(); (void)defProbe.view();
    for( std::size_t i = 0; i < fixture.defs[0].evWhy.size(); ++i ) { (void)defProbe.u8(); }
    (void)defProbe.u32();
    const std::size_t postingsCountOffset = std::size_t( defProbe.p - encoded.bytes.data() );
    REQUIRE( defProbe.u32() == fixture.defs[0].lex.tokenHashes.size() );
    (void)rw::readDef( reader, true, fileDict );

    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 ); (void)rw::readRef( reader );
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 );
    for( std::size_t i = 0; i < 3; ++i ) { (void)reader.u8(); }
    (void)reader.u32(); (void)reader.view();
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 ); (void)rw::readBind( reader );
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 ); (void)rw::readFfi( reader );
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 ); (void)rw::readRouteDef( reader );
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 ); (void)rw::readRouteUse( reader );
    countOffsets.push_back( std::size_t( reader.p - encoded.bytes.data() ) );
    REQUIRE( reader.u32() == 1 );
    (void)reader.u32(); (void)reader.u32(); (void)reader.u8(); (void)reader.view();
    REQUIRE( reader.ok );
    REQUIRE( reader.p == reader.end );

    rw::CacheDecodeScratch scratch;
    std::vector<std::size_t> mutationOffsets{ dictCountOffset, postingsCountOffset };
    mutationOffsets.insert( mutationOffsets.end(), countOffsets.begin(), countOffsets.end() );
    for( const std::size_t offset : mutationOffsets )
    {
        CAPTURE( offset );
        std::string mutated = encoded.bytes;
        replaceU32( mutated, offset, std::numeric_limits<std::uint32_t>::max() );
        rw::CacheRecordExpectation expected = valid;
        expected.sum = rw::recordSum32( mutated );
        checkRejectedTransactionally( mutated, expected, scratch );
    }
}

void checkCompleteBoundaryRecord()
{
    Fixture fixture;
    fixture.defs.clear(); fixture.refs.clear(); fixture.incs.clear(); fixture.binds.clear(); fixture.ffis.clear();
    fixture.routeDefs.clear(); fixture.routeUses.clear(); fixture.constOpens.clear();
    rw::ConstOpen open;
    open.startByte = 1; open.endByte = 2; open.namespaceOnly = true;
    fixture.constOpens.push_back( open );
    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, false );
    REQUIRE( encoded.bytes.size() >= 17 );
    std::uint32_t count = 0;
    std::memcpy( &count, encoded.bytes.data() + encoded.bytes.size() - 17, sizeof( count ) );
    CHECK( count == 1 );
    CHECK( encoded.bytes.size() - ( encoded.bytes.size() - 17 + sizeof( count ) ) == 13 );

    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    std::vector<rw::RawDef> defs; std::vector<rw::RawRef> refs; std::vector<rw::Include> incs;
    std::vector<rw::RawBind> binds; std::vector<rw::BindingAlias> ffis; std::vector<rw::RouteDef> routeDefs;
    std::vector<rw::RawRouteUse> routeUses; std::vector<rw::ConstOpen> constOpens; rw::FileHealth health;
    long long size = -1, mtime = -1, ctime = -1;
    rw::CacheDecodeOutput output{ defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime };
    const rw::CacheRecordExpectation expected{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, false };
    REQUIRE( rw::decodeCacheRecord( encoded.bytes, expected, output ) );
    REQUIRE( constOpens.size() == 1 );
    CHECK( constOpens[0].startByte == 1 ); CHECK( constOpens[0].endByte == 2 );
    CHECK( constOpens[0].namespaceOnly ); CHECK( constOpens[0].written.empty() );
}

std::vector<rw::RawDef> decodeDefs( const Fixture& fixture, const rw::EncodedCacheRecord& encoded, const bool rich )
{
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    std::vector<rw::RawDef> defs; std::vector<rw::RawRef> refs; std::vector<rw::Include> incs;
    std::vector<rw::RawBind> binds; std::vector<rw::BindingAlias> ffis; std::vector<rw::RouteDef> routeDefs;
    std::vector<rw::RawRouteUse> routeUses; std::vector<rw::ConstOpen> constOpens; rw::FileHealth health;
    long long size = -1, mtime = -1, ctime = -1;
    rw::CacheDecodeOutput output{ defs, refs, incs, binds, ffis, routeDefs, routeUses, constOpens, health, size, mtime, ctime };
    const rw::CacheRecordExpectation expected{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, rich };
    REQUIRE( rw::decodeCacheRecord( encoded.bytes, expected, output ) );
    return defs;
}

void checkDictionaryIndexWidth( const std::size_t dictCount, const unsigned expectedWidth )
{
    Fixture fixture;
    fixture.defs.resize( 1 );
    rw::RawDef& def = fixture.defs[0];
    def.lex.tokenHashes.clear(); def.lex.tokenTfs.clear();
    def.lex.tokenHashes.reserve( dictCount ); def.lex.tokenTfs.reserve( dictCount );
    for( std::size_t i = 0; i < dictCount; ++i )
    {
        def.lex.tokenHashes.push_back( 0x100000000ull + i );
        def.lex.tokenTfs.push_back( std::uint32_t( i % 251 + 1 ) );
    }
    CHECK( rw::lexDictIndexWidth( dictCount ) == expectedWidth );
    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, true );
    std::vector<rw::RawDef> defs = decodeDefs( fixture, encoded, true );
    REQUIRE( defs.size() == 1 );
    CHECK( defs[0].lex.tokenHashes == def.lex.tokenHashes );
    CHECK( defs[0].lex.tokenTfs == def.lex.tokenTfs );
    fixture.defs = defs;
    CHECK( encodeFixture( fixture, true ).bytes == encoded.bytes );
}

TEST_CASE( "cache byte reader rejects every short or huge read without additive pointer arithmetic" )
{
    std::array<char, 8> bytes{};
    rw::ByteR r32{ bytes.data(), bytes.data() + 3 };
    CHECK( r32.remaining() == 3 );
    CHECK( r32.u32() == 0 );
    CHECK_FALSE( r32.ok );
    CHECK( r32.p == bytes.data() );

    rw::ByteR r64{ bytes.data(), bytes.data() + 7 };
    CHECK( r64.u64() == 0 );
    CHECK_FALSE( r64.ok );
    CHECK( r64.p == bytes.data() );

    rw::ByteW length;
    length.u32( std::numeric_limits<std::uint32_t>::max() );
    rw::ByteR view{ length.b.data(), length.b.data() + length.b.size() };
    CHECK( view.view().empty() );
    CHECK_FALSE( view.ok );
    CHECK( view.p == length.b.data() + 4 );

    char destination = '\0';
    rw::ByteR raw{ bytes.data(), bytes.data() + bytes.size() };
    CHECK_FALSE( raw.rawInto( &destination, std::numeric_limits<std::size_t>::max() ) );
    CHECK_FALSE( raw.ok );
    CHECK( raw.p == bytes.data() );
}

TEST_CASE( "cache record count bound accepts the exact maximum and rejects maximum plus one" )
{
    std::array<char, 52> bytes{};
    rw::ByteR exact{ bytes.data(), bytes.data() + bytes.size() };
    CHECK( rw::cacheRecordCountFits( exact, 2, 26 ) );
    CHECK( exact.ok );
    CHECK( exact.remaining() == bytes.size() );

    rw::ByteR over{ bytes.data(), bytes.data() + bytes.size() };
    CHECK_FALSE( rw::cacheRecordCountFits( over, 3, 26 ) );
    CHECK_FALSE( over.ok );
    CHECK( over.remaining() == bytes.size() );
}

TEST_CASE( "cache record decode rejects every malformed identity and truncation transactionally" )
{
    Fixture fixture;
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, true );
    const rw::CacheRecordExpectation valid{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], encoded.sum, true };
    rw::CacheDecodeScratch scratch;

    rw::CacheRecordExpectation wrong = valid;
    ++wrong.sum;
    checkRejectedTransactionally( encoded.bytes, wrong, scratch );
    wrong = valid; wrong.relativePath = "other.cpp";
    checkRejectedTransactionally( encoded.bytes, wrong, scratch );
    wrong = valid; ++wrong.pathHash;
    checkRejectedTransactionally( encoded.bytes, wrong, scratch );
    wrong = valid; ++wrong.contentHash;
    checkRejectedTransactionally( encoded.bytes, wrong, scratch );

    std::string trailing = encoded.bytes;
    trailing.push_back( '\0' );
    wrong = valid; wrong.sum = rw::recordSum32( trailing );
    checkRejectedTransactionally( trailing, wrong, scratch );

    for( std::size_t size = 0; size < encoded.bytes.size(); ++size )
    {
        CAPTURE( size );
        const std::string_view truncated( encoded.bytes.data(), size );
        wrong = valid; wrong.sum = rw::recordSum32( truncated );
        checkRejectedTransactionally( truncated, wrong, scratch );
    }

    std::string hugeLength = encoded.bytes;
    const std::uint32_t maximum = std::numeric_limits<std::uint32_t>::max();
    std::memcpy( hugeLength.data(), &maximum, sizeof( maximum ) );
    wrong = valid; wrong.sum = rw::recordSum32( hugeLength );
    checkRejectedTransactionally( hugeLength, wrong, scratch );
}

TEST_CASE( "cache records preserve separate one two and four byte term-frequency rows" )
{
    Fixture fixture;
    const rw::RawDef prototype = fixture.defs[0];
    fixture.defs.clear();
    constexpr std::array<std::uint32_t, 3> frequencies{ 0xffu, 0xffffu, 0xffffffffu };
    for( std::size_t row = 0; row < frequencies.size(); ++row )
    {
        rw::RawDef def = prototype;
        def.name = "width-" + std::to_string( row );
        def.lex.tokenHashes = { 0x1000u + row };
        def.lex.tokenTfs = { frequencies[row] };
        fixture.defs.push_back( std::move( def ) );
    }

    const rw::EncodedCacheRecord encoded = encodeFixture( fixture, true );
    const std::vector<rw::RawDef> defs = decodeDefs( fixture, encoded, true );
    REQUIRE( defs.size() == frequencies.size() );
    for( std::size_t row = 0; row < frequencies.size(); ++row )
    {
        REQUIRE( defs[row].lex.tokenTfs.size() == 1 );
        CHECK( defs[row].lex.tokenTfs[0] == frequencies[row] );
    }
}

TEST_CASE( "cache codec reuses caller scratch and appends records directly" )
{
    Fixture fixture;
    for( std::size_t row = 1; row < 3; ++row )
    {
        rw::RawDef def = fixture.defs[0];
        def.name = "scratch-" + std::to_string( row );
        def.lex.tokenHashes = { 0x3132333435363700ull + row };
        def.lex.tokenTfs = { std::uint32_t( row ) };
        fixture.defs.push_back( std::move( def ) );
    }
    const rw::CachePathKeys keys = rw::buildCachePathKeys( fixture.files, "/fixture" );
    const rw::CacheFileIndexes indexes = rw::buildCacheFileIndexes( fixture.files.size(), fixture.defs, fixture.refs, fixture.incs,
                                                                    fixture.binds, fixture.ffis, fixture.routeDefs,
                                                                    fixture.routeUses, fixture.constOpens );
    const rw::CacheEncodeInput input = inputFor( fixture, true );
    const rw::EncodedCacheRecord owned = rw::encodeCacheRecord( 0, keys, indexes, input );

    rw::CacheEncodeScratch scratch;
    rw::ByteW destination;
    destination.raw( "prefix", 6 );
    const rw::CacheEntry first = rw::appendCacheRecord( destination, 0, keys, indexes, input, scratch );
    CHECK( first.recOffset == 6 );
    CHECK( first.recLength == owned.bytes.size() );
    CHECK( std::string_view( destination.b ).substr( first.recOffset, first.recLength ) == owned.bytes );

    const std::array<std::size_t, 6> capacities{ scratch.fileDict.capacity(), scratch.mergeA.capacity(), scratch.mergeB.capacity(),
                                                 scratch.runOffsets.capacity(), scratch.nextRunOffsets.capacity(),
                                                 scratch.pairDictIndex.capacity() };
    for( const std::size_t capacity : capacities )
    {
        CHECK( capacity > 0 );
    }
    const rw::CacheEntry second = rw::appendCacheRecord( destination, 0, keys, indexes, input, scratch );
    CHECK( second.recOffset == first.recOffset + first.recLength );
    CHECK( destination.b.size() == 6 + 2 * owned.bytes.size() );
    CHECK( scratch.fileDict.capacity() == capacities[0] );
    CHECK( scratch.mergeA.capacity() == capacities[1] );
    CHECK( scratch.mergeB.capacity() == capacities[2] );
    CHECK( scratch.runOffsets.capacity() == capacities[3] );
    CHECK( scratch.nextRunOffsets.capacity() == capacities[4] );
    CHECK( scratch.pairDictIndex.capacity() == capacities[5] );

    DecodeDestination firstDecode;
    rw::CacheDecodeOutput firstOutput = firstDecode.output();
    rw::CacheDecodeScratch decodeScratch;
    const rw::CacheRecordExpectation expected{ keys.rels[0], keys.pathHashes[0], fixture.fileHash[0], owned.sum, true };
    REQUIRE( rw::decodeCacheRecordWithScratch( owned.bytes, expected, firstOutput, decodeScratch ) );
    const std::size_t decodeCapacity = decodeScratch.fileDict.capacity();
    DecodeDestination secondDecode;
    rw::CacheDecodeOutput secondOutput = secondDecode.output();
    REQUIRE( rw::decodeCacheRecordWithScratch( owned.bytes, expected, secondOutput, decodeScratch ) );
    CHECK( decodeScratch.fileDict.capacity() == decodeCapacity );
}

TEST_CASE( "lean and rich cache records round trip every serialized field byte identically" )
{
    checkComprehensiveRoundTrip( false );
    checkComprehensiveRoundTrip( true );
}

TEST_CASE( "serialized cache counts reject corrupt values and accept a complete boundary record" )
{
    checkSerializedCountMutations();
    checkCompleteBoundaryRecord();
}

TEST_CASE( "rich cache records round trip two and four byte dictionary indices" )
{
    checkDictionaryIndexWidth( 0x101u, 2 );
    checkDictionaryIndexWidth( 0x10001u, 4 );
}

TEST_CASE( "cache record architecture discriminator matches the native wire contract" )
{
    constexpr std::uint8_t endianBit = std::endian::native == std::endian::big ? 1u : 0u;
    constexpr std::uint8_t expected = endianBit | static_cast<std::uint8_t>( sizeof( void* ) << 1 );
    CHECK( rw::kArtifactArch == expected );
    CHECK( sizeof( std::uint32_t ) == 4 );
    CHECK( sizeof( std::uint64_t ) == 8 );
}
#endif

}

int main( int argc, char** argv )
{
    if( argc == 4 && std::string_view( argv[1] ) == "--write-records" )
    {
#if defined( CACHE_RECORD_BASELINE_DRIVER )
        return writeLegacyRecord( argv[2], false ) && writeLegacyRecord( argv[3], true ) ? 0 : 1;
#else
        return writeCurrentRecord( argv[2], false ) && writeCurrentRecord( argv[3], true ) ? 0 : 1;
#endif
    }
#if defined( CACHE_RECORD_BASELINE_DRIVER )
    return 2;
#else
    doctest::Context context( argc, argv );
    return context.run();
#endif
}
