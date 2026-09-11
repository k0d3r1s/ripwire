#include "editpreview.h"   // the same pre-apply declarations supplied before mcp.h by main.cpp
#include "mcp.h"
#include "redis_client.h"

#include <iostream>

namespace
{
rw::CacheContext redisProbeContext( const std::string& root )
{
    std::shared_ptr<const rw::CachePolicy> policy;
    std::string error;
    rw::CacheContext cache;
    if( !rw::resolveCachePolicy( { false, true, "redis", {} }, policy, error )
        || !rw::cacheContextForRoot( policy, root, true, cache, error ) )
    {
        std::cerr << error << '\n';
        std::exit( 2 );
    }
    return cache;
}

int spanProbe( const std::string& root, const std::string& path )
{
    const auto cache = redisProbeContext( root );
    const std::vector<std::string> paths{ path };
    const auto batch = rw::spanTiersOfFiles( paths, true, &cache );
    if( batch.perFile.size() != 1 || !batch.perFile[0].isParsed ) { return 2; }
    std::cout << batch.bytesParsed << '\n';
    return 0;
}

int lockProbe( const std::string& root, const std::string& target, const std::string& sidecar )
{
    const auto cache = redisProbeContext( root );
    rw::mcpUseCachePolicy( cache.policy );
    {
        rw::mcpedit::EditLock edit( target );
        rw::quality::SidecarWriteLock ledger( sidecar );
        if( !edit.locked || !ledger.locked ) { return 2; }
        std::cout << "locked" << std::endl;
        std::string release;
        if( !std::getline( std::cin, release ) || release != "release" ) { return 2; }
    }
    std::cout << "released" << std::endl;
    return 0;
}

std::string treeProbeValue( const std::string& root, const std::string& family, const rw::CacheContext& cache )
{
    if( family == "qsnap" )
    {
        const auto result = rw::quality::computeHeadSnapshot( root, nullptr, rw::kDefaultMaxFileBytes, {}, cache );
        return result.second ? rw::quality::serializeSnapshot( result.first, "probe" ) : std::string{};
    }
    const auto result = rw::quality::computeWindowRefBodyHashes( root, 90, {}, rw::kDefaultMaxFileBytes, cache );
    rw::quality::Snapshot body;
    body.bodyHashBySym = result.first;
    return result.second ? rw::quality::serializeSnapshot( body, "probe" ) : std::string{};
}

int treeProbe( const std::string& root, const std::string& family, bool overlap )
{
    const auto cache = redisProbeContext( root );
    if( !overlap )
    {
        const std::string value = treeProbeValue( root, family, cache );
        std::cout << value;
        return value.empty() ? 2 : 0;
    }
    std::string first, second;
    std::thread prefetch( [&] { first = treeProbeValue( root, family, cache ); } );
    std::string release;
    const bool startLazy = std::getline( std::cin, release ) && release == "lazy";
    if( !startLazy ) { prefetch.join(); return 2; }
    auto lazyCache = cache;
    lazyCache.project += "-lazy"; // guaranteed cold while the first immutable publication is held
    std::thread lazy( [&] { second = treeProbeValue( root, family, lazyCache ); } );
    prefetch.join();
    std::cout << "prefetch-done" << std::endl;
    lazy.join();
    if( first.empty() || first != second ) { return 2; }
    std::cout << first;
    return 0;
}
}

// Default still exercises the source-compatible MCP API without CLI policy resolution.
int main( int argc, char** argv )
{
    const int helper = rw::runRedisResolverHelperIfRequested( argc, argv );
    if( helper >= 0 ) { return helper; }
    if( argc == 4 && std::string_view( argv[1] ) == "--cache-span-probe" ) { return spanProbe( argv[2], argv[3] ); }
    if( argc == 5 && std::string_view( argv[1] ) == "--cache-lock-probe" ) { return lockProbe( argv[2], argv[3], argv[4] ); }
    if( argc == 4 && std::string_view( argv[1] ) == "--cache-tree-probe" ) { return treeProbe( argv[2], argv[3], false ); }
    if( argc == 4 && std::string_view( argv[1] ) == "--cache-tree-overlap" ) { return treeProbe( argv[2], argv[3], true ); }
    return rw::runMcp( 200 );
}
