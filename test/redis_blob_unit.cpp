#include "redis_client.h"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

namespace
{
void require( bool ok, const char* message )
{
    if( !ok ) { std::cerr << message << '\n'; std::exit( 1 ); }
}

void verifyFileBlobApi( const std::string& executable, const rw::CacheContext& cache )
{
    rw::CacheBlobAddress defaultFile{ rw::CacheBlobFamily::QualityBody, 1, rw::kArtifactArch, "ignored", executable + ".blob" };
    const std::string defaultPayload( "opaque\0file", 11 );
    std::string defaultBytes;
    require( rw::storeCacheBlob( {}, defaultFile, defaultPayload ), "default File atomic store" );
    require( rw::probeCacheBlob( {}, defaultFile, defaultBytes ) == rw::CacheProbeStatus::Hit && defaultBytes == defaultPayload, "default File opaque roundtrip" );
    require( std::filesystem::remove( defaultFile.localPath ), "remove test File blob" );
    require( rw::probeCacheBlob( {}, defaultFile, defaultBytes ) == rw::CacheProbeStatus::Miss && defaultBytes.empty(), "default File missing path" );
    rw::CacheBlobAddress local{ rw::CacheBlobFamily::QualitySnapshot, 1, rw::kArtifactArch, "ignored", "original-path" };
    local.fileProbe = []( const std::string& path, std::string& bytes )
    {
        if( path != "original-path" ) { return -1; }
        bytes = "original-bytes";
        return 1;
    };
    local.fileStore = []( const std::string& path, const std::string& bytes ) { return path == "original-path" && bytes == "original-bytes"; };
    std::string localBytes;
    require( rw::probeCacheBlob( {}, local, localBytes ) == rw::CacheProbeStatus::Hit && localBytes == "original-bytes", "File delegates original probe" );
    require( rw::storeCacheBlob( {}, local, localBytes ), "File delegates original atomic writer" );
    auto disabled = std::make_shared<rw::CachePolicy>();
    rw::CacheContext disabledCache{ disabled, {}, {}, true };
    require( rw::probeCacheBlob( disabledCache, local, localBytes ) == rw::CacheProbeStatus::Miss && localBytes.empty(), "Disabled never invokes File probe" );
    require( !rw::storeCacheBlob( disabledCache, local, "original-bytes" ), "Disabled never invokes File writer" );
    auto unavailablePolicy = std::make_shared<rw::CachePolicy>( *cache.policy );
    unavailablePolicy->redis.endpoint = "invalid";
    rw::CacheContext unavailable{ unavailablePolicy, {}, cache.project, true };
    require( rw::probeCacheBlob( unavailable, local, localBytes ) == rw::CacheProbeStatus::Unavailable && localBytes.empty(), "Redis failure never invokes local probe" );
    require( !rw::storeCacheBlob( unavailable, local, "original-bytes" ), "Redis failure never invokes local writer" );
}
}

// This driver exercises the public blob API, including identities that cannot be represented in argv.
int main( int argc, char** argv )
{
    const int helper = rw::runRedisResolverHelperIfRequested( argc, argv );
    if( helper >= 0 ) { return helper; }
    if( argc != 2 ) { return 2; }
    auto policy = std::make_shared<rw::CachePolicy>();
    policy->kind = rw::CacheBackendKind::Redis;
    policy->redis.endpoint = argv[1];
    policy->redis.nameSpace = std::string( "api:{namespace}\r\n\0", 18 );
    policy->redis.ttlSeconds = 86400;
    rw::CacheContext cache{ policy, {}, std::string( "project:\0}\r\n", 12 ), true };
    verifyFileBlobApi( argv[0], cache );
    for( unsigned familyId = 0; familyId < 6; ++familyId )
    {
        rw::CacheBlobAddress address{ static_cast<rw::CacheBlobFamily>( familyId ), 4242, rw::kArtifactArch,
                                      std::string( "identity:{x}\r\n\0", 15 ) + std::string( 8192, 'z' ), "/never/read/or/write/local/path" };
        const std::string payload( "blob\0\r\n", 7 );
        std::string bytes = "sentinel";
        require( rw::probeCacheBlob( cache, address, bytes ) == rw::CacheProbeStatus::Miss && bytes.empty(), "initial miss" );
        require( rw::storeCacheBlob( cache, address, payload ), "store binary payload" );
        address.localPath = "/different/local/path/does/not/change/redis/identity";
        require( rw::probeCacheBlob( cache, address, bytes ) == rw::CacheProbeStatus::Hit && bytes == payload, "binary hit ignores localPath" );
        auto different = address;
        different.schemeVersion++;
        require( rw::probeCacheBlob( cache, different, bytes ) == rw::CacheProbeStatus::Miss, "scheme isolation" );
        different = address;
        different.artifactArch ^= 1u;
        require( rw::probeCacheBlob( cache, different, bytes ) == rw::CacheProbeStatus::Miss, "foreign architecture isolation" );
        require( !rw::storeCacheBlob( cache, different, payload ), "foreign architecture must never publish native bytes" );
        different = address;
        different.identity += '\0';
        require( rw::probeCacheBlob( cache, different, bytes ) == rw::CacheProbeStatus::Miss, "embedded NUL is not truncated" );
        auto otherProject = cache;
        otherProject.project += ':';
        require( rw::probeCacheBlob( otherProject, address, bytes ) == rw::CacheProbeStatus::Miss, "project isolation" );
    }
    rw::CacheBlobAddress address{ rw::CacheBlobFamily::QualityBody, 4243, rw::kArtifactArch, "size-boundary", {} };
    require( !rw::storeCacheBlob( cache, address, std::string( 64u * 1024u * 1024u, 'x' ) ), "oversize blob must be refused" );
    const std::string large( 9u * 1024u * 1024u, 'y' );
    std::string bytes;
    require( rw::storeCacheBlob( cache, address, large ), "blob above former 8MiB request ceiling" );
    require( rw::probeCacheBlob( cache, address, bytes ) == rw::CacheProbeStatus::Hit && bytes == large, "large binary round trip" );
    address.family = static_cast<rw::CacheBlobFamily>( 255 );
    require( !rw::storeCacheBlob( cache, address, "lock or tree" ), "closed family map" );
    std::cout << "  PASS  public blob API binary identities, architecture/scheme/project isolation, closed families and size bounds\n";
}
