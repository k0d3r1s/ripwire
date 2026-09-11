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
}

// Default still exercises the source-compatible MCP API without CLI policy resolution.
int main( int argc, char** argv )
{
    const int helper = rw::runRedisResolverHelperIfRequested( argc, argv );
    if( helper >= 0 ) { return helper; }
    if( argc == 4 && std::string_view( argv[1] ) == "--cache-span-probe" ) { return spanProbe( argv[2], argv[3] ); }
    if( argc == 5 && std::string_view( argv[1] ) == "--cache-lock-probe" ) { return lockProbe( argv[2], argv[3], argv[4] ); }
    return rw::runMcp( 200 );
}
