#include "redis_client.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <limits>
#include <memory>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <vector>

namespace rw
{
namespace
{

constexpr std::size_t kMaximumBulkBytes = 64u * 1024u * 1024u;
constexpr std::size_t kMaximumArrayElements = 4096;
constexpr std::size_t kMaximumReplyNodes = 16384;
constexpr std::size_t kMaximumReplyDepth = 4;
constexpr std::size_t kMaximumAggregateBytes = 128u * 1024u * 1024u;
constexpr std::size_t kMaximumPipelineCommands = 256;
constexpr std::size_t kMaximumRequestBytes = 8u * 1024u * 1024u;

enum class EndpointKind : std::uint8_t { Tcp, Unix };
enum class ParseStatus : std::uint8_t { Complete, NeedMore, Invalid };

struct Endpoint
{
    EndpointKind kind = EndpointKind::Tcp;
    std::string host;
    std::string port = "6379";
    std::string path;
    std::uint32_t database = 0;
};

struct ParseContext
{
    std::string_view input;
    std::size_t position = 0;
    std::size_t nodeCount = 0;
    std::size_t aggregateBytes = 0;
    std::size_t aggregateLimit = kMaximumAggregateBytes;
};

struct ParseOutcome
{
    ParseStatus status = ParseStatus::Invalid;
    std::vector<RedisReply> replies;
};

class SocketHandle
{
  public:
    SocketHandle() = default;
    explicit SocketHandle( const int value ) : value_( value ) {}
    ~SocketHandle()
    {
        if( value_ >= 0 )
        {
            close( value_ );
        }
    }
    SocketHandle( const SocketHandle& ) = delete;
    SocketHandle& operator=( const SocketHandle& ) = delete;
    SocketHandle( SocketHandle&& other ) noexcept : value_( other.value_ ) { other.value_ = -1; }
    SocketHandle& operator=( SocketHandle&& ) = delete;
    [[nodiscard]] int get() const noexcept { return value_; }
    [[nodiscard]] explicit operator bool() const noexcept { return value_ >= 0; }

  private:
    int value_ = -1;
};

using Deadline = std::chrono::steady_clock::time_point;

const char* failureName( const RedisFailure failure ) noexcept
{
    constexpr std::array<const char*, 8> names{ "none", "config", "connect", "timeout", "protocol", "auth", "cluster redirect", "server" };
    const std::size_t index = static_cast<std::size_t>( failure );
    return index < names.size() ? names[index] : "server";
}

std::string endpointName( const EndpointKind kind )
{
    return kind == EndpointKind::Unix ? "unix" : "tcp";
}

RedisResult failureResult( const RedisFailure failure, const std::string_view endpointClass, const std::string_view category = {} )
{
    RedisResult result;
    result.failure = failure;
    result.diagnostic = "redis " + std::string( endpointClass ) + ": " + failureName( failure );
    if( !category.empty() )
    {
        result.diagnostic += " ";
        result.diagnostic += category;
    }
    return result;
}

bool containsForbiddenUrlByte( const std::string_view value ) noexcept
{
    return std::any_of( value.begin(), value.end(), []( const unsigned char byte ) { return byte <= 0x20 || byte == 0x7f; } );
}

bool parseDecimalMagnitude( const std::string_view digits, const std::uint64_t maximum, std::uint64_t& output ) noexcept
{
    if( digits.empty() )
    {
        return false;
    }
    std::uint64_t value = 0;
    for( const unsigned char digit : digits )
    {
        if( digit < '0' || digit > '9' )
        {
            return false;
        }
        const std::uint64_t numeric = digit - '0';
        if( value > ( maximum - numeric ) / 10 )
        {
            return false;
        }
        value = value * 10 + numeric;
    }
    output = value;
    return true;
}

bool parseUnsigned( const std::string_view value, std::uint32_t& output, const std::uint32_t maximum ) noexcept
{
    std::uint64_t parsed = 0;
    if( !parseDecimalMagnitude( value, maximum, parsed ) )
    {
        return false;
    }
    output = static_cast<std::uint32_t>( parsed );
    return true;
}

bool parseEndpoint( const std::string_view value, Endpoint& output )
{
    if( value.empty() || value.size() > 4096 || containsForbiddenUrlByte( value ) || value.find( '%' ) != std::string_view::npos
        || value.find( '#' ) != std::string_view::npos || value.find( '@' ) != std::string_view::npos )
    {
        return false;
    }
    Endpoint parsed;
    if( value.starts_with( "redis://" ) )
    {
        const std::string_view remainder = value.substr( 8 );
        if( remainder.empty() || remainder.find( '?' ) != std::string_view::npos )
        {
            return false;
        }
        const std::size_t slash = remainder.find( '/' );
        const std::string_view authority = remainder.substr( 0, slash );
        const std::string_view database = slash == std::string_view::npos ? std::string_view() : remainder.substr( slash + 1 );
        if( authority.empty() || ( slash != std::string_view::npos && ( database.empty() || database.find( '/' ) != std::string_view::npos ) ) )
        {
            return false;
        }
        std::string_view host;
        std::string_view port;
        if( authority.front() == '[' )
        {
            const std::size_t close = authority.find( ']' );
            if( close == std::string_view::npos || close == 1 || authority.find( '[', 1 ) != std::string_view::npos
                || authority.find( ']', close + 1 ) != std::string_view::npos )
            {
                return false;
            }
            host = authority.substr( 1, close - 1 );
            in6_addr address{};
            if( inet_pton( AF_INET6, std::string( host ).c_str(), &address ) != 1 )
            {
                return false;
            }
            const std::string_view suffix = authority.substr( close + 1 );
            if( !suffix.empty() )
            {
                if( suffix.front() != ':' || suffix.size() == 1 )
                {
                    return false;
                }
                port = suffix.substr( 1 );
            }
        }
        else
        {
            if( authority.find( '[' ) != std::string_view::npos || authority.find( ']' ) != std::string_view::npos )
            {
                return false;
            }
            const std::size_t colon = authority.find( ':' );
            if( colon == std::string_view::npos )
            {
                host = authority;
            }
            else
            {
                if( authority.find( ':', colon + 1 ) != std::string_view::npos || colon == 0 || colon + 1 == authority.size() )
                {
                    return false;
                }
                host = authority.substr( 0, colon );
                port = authority.substr( colon + 1 );
            }
        }
        if( host.empty() || host.find_first_of( "/\\" ) != std::string_view::npos )
        {
            return false;
        }
        std::uint32_t portNumber = 6379;
        if( !port.empty() && ( !parseUnsigned( port, portNumber, 65535 ) || portNumber == 0 ) )
        {
            return false;
        }
        if( !database.empty() && !parseUnsigned( database, parsed.database, std::numeric_limits<std::int32_t>::max() ) )
        {
            return false;
        }
        parsed.kind = EndpointKind::Tcp;
        parsed.host = host;
        parsed.port = std::to_string( portNumber );
    }
    else if( value.starts_with( "redis+unix://" ) )
    {
        const std::string_view remainder = value.substr( 13 );
        if( remainder.empty() || remainder.front() != '/' )
        {
            return false;
        }
        const std::size_t query = remainder.find( '?' );
        const std::string_view path = remainder.substr( 0, query );
        if( path.empty() || path.find( "//" ) != std::string_view::npos || path.ends_with( "/" ) )
        {
            return false;
        }
        std::size_t segmentStart = 1;
        while( segmentStart < path.size() )
        {
            const std::size_t segmentEnd = path.find( '/', segmentStart );
            const std::string_view segment = path.substr( segmentStart, segmentEnd - segmentStart );
            if( segment == "." || segment == ".." )
            {
                return false;
            }
            if( segmentEnd == std::string_view::npos )
            {
                break;
            }
            segmentStart = segmentEnd + 1;
        }
        if( query != std::string_view::npos )
        {
            const std::string_view parameter = remainder.substr( query + 1 );
            if( !parameter.starts_with( "db=" ) || parameter.find( '&' ) != std::string_view::npos
                || !parseUnsigned( parameter.substr( 3 ), parsed.database, std::numeric_limits<std::int32_t>::max() ) )
            {
                return false;
            }
        }
        parsed.kind = EndpointKind::Unix;
        parsed.path = path;
    }
    else
    {
        return false;
    }
    output = std::move( parsed );
    return true;
}

bool isLoopbackAddress( const sockaddr* address ) noexcept
{
    if( address->sa_family == AF_INET )
    {
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>( address );
        return ( ntohl( ipv4->sin_addr.s_addr ) & 0xff000000u ) == 0x7f000000u;
    }
    if( address->sa_family == AF_INET6 )
    {
        const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>( address );
        if( IN6_IS_ADDR_LOOPBACK( &ipv6->sin6_addr ) )
        {
            return true;
        }
        if( IN6_IS_ADDR_V4MAPPED( &ipv6->sin6_addr ) )
        {
            std::uint32_t ipv4 = 0;
            std::memcpy( &ipv4, &ipv6->sin6_addr.s6_addr[12], sizeof( ipv4 ) );
            return ( ntohl( ipv4 ) & 0xff000000u ) == 0x7f000000u;
        }
    }
    return false;
}

bool setDescriptorFlags( const int descriptor ) noexcept
{
    const int descriptorFlags = fcntl( descriptor, F_GETFD, 0 );
    const int statusFlags = fcntl( descriptor, F_GETFL, 0 );
    return descriptorFlags >= 0 && statusFlags >= 0 && fcntl( descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC ) == 0
           && fcntl( descriptor, F_SETFL, statusFlags | O_NONBLOCK ) == 0;
}

int remainingMilliseconds( const Deadline deadline ) noexcept
{
    const auto remaining = deadline - std::chrono::steady_clock::now();
    if( remaining <= Deadline::duration::zero() )
    {
        return 0;
    }
    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>( remaining );
    if( milliseconds.count() >= std::numeric_limits<int>::max() )
    {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>( milliseconds.count() + ( milliseconds < remaining ? 1 : 0 ) );
}

bool waitForSocket( const int descriptor, const short events, const Deadline deadline, bool& timedOut ) noexcept
{
    timedOut = false;
    while( true )
    {
        const int remaining = remainingMilliseconds( deadline );
        if( remaining == 0 )
        {
            timedOut = true;
            return false;
        }
        pollfd request{ descriptor, events, 0 };
        const int result = poll( &request, 1, remaining );
        if( result > 0 )
        {
            return true;
        }
        if( result == 0 )
        {
            timedOut = true;
            return false;
        }
        if( errno != EINTR )
        {
            return false;
        }
    }
}

RedisFailure finishConnect( const int descriptor, const sockaddr* address, const socklen_t addressLength, const Deadline deadline ) noexcept
{
    if( connect( descriptor, address, addressLength ) == 0 )
    {
        return RedisFailure::None;
    }
    if( errno != EINPROGRESS && errno != EWOULDBLOCK )
    {
        return RedisFailure::Connect;
    }
    bool timedOut = false;
    if( !waitForSocket( descriptor, POLLOUT, deadline, timedOut ) )
    {
        return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    int socketError = 0;
    socklen_t socketErrorLength = sizeof( socketError );
    if( getsockopt( descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength ) != 0 || socketError != 0 )
    {
        return socketError == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    return RedisFailure::None;
}

SocketHandle connectTcp( const Endpoint& endpoint, const bool allowRemote, const Deadline deadline, RedisFailure& failure )
{
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* rawAddresses = nullptr;
    if( getaddrinfo( endpoint.host.c_str(), endpoint.port.c_str(), &hints, &rawAddresses ) != 0 )
    {
        failure = RedisFailure::Connect;
        return {};
    }
    const std::unique_ptr<addrinfo, decltype( &freeaddrinfo )> addresses( rawAddresses, freeaddrinfo );
    if( remainingMilliseconds( deadline ) == 0 )
    {
        failure = RedisFailure::Timeout;
        return {};
    }
    for( const addrinfo* candidate = addresses.get(); candidate; candidate = candidate->ai_next )
    {
        if( candidate->ai_family != AF_INET && candidate->ai_family != AF_INET6 )
        {
            failure = RedisFailure::Connect;
            return {};
        }
        if( !allowRemote && !isLoopbackAddress( candidate->ai_addr ) )
        {
            failure = RedisFailure::Connect;
            return {};
        }
    }
    RedisFailure lastFailure = RedisFailure::Connect;
    for( const addrinfo* candidate = addresses.get(); candidate; candidate = candidate->ai_next )
    {
        SocketHandle descriptor( socket( candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol ) );
        if( !descriptor || !setDescriptorFlags( descriptor.get() ) )
        {
            continue;
        }
#if defined( SO_NOSIGPIPE )
        const int enabled = 1;
        setsockopt( descriptor.get(), SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof( enabled ) );
#endif
        lastFailure = finishConnect( descriptor.get(), candidate->ai_addr, static_cast<socklen_t>( candidate->ai_addrlen ), deadline );
        if( lastFailure != RedisFailure::None )
        {
            if( lastFailure == RedisFailure::Timeout )
            {
                break;
            }
            continue;
        }
        sockaddr_storage peer{};
        socklen_t peerLength = sizeof( peer );
        if( getpeername( descriptor.get(), reinterpret_cast<sockaddr*>( &peer ), &peerLength ) != 0
            || ( !allowRemote && !isLoopbackAddress( reinterpret_cast<const sockaddr*>( &peer ) ) ) )
        {
            lastFailure = RedisFailure::Connect;
            continue;
        }
        failure = RedisFailure::None;
        return descriptor;
    }
    failure = lastFailure;
    return {};
}

bool safeOwner( const uid_t owner ) noexcept
{
    return owner == 0 || owner == geteuid();
}

bool validateUnixPath( const std::string& path, struct stat& endpointStatus ) noexcept
{
    std::string parent = "/";
    std::size_t position = 1;
    while( true )
    {
        const std::size_t slash = path.find( '/', position );
        if( slash == std::string::npos )
        {
            break;
        }
        if( parent.size() > 1 )
        {
            parent += '/';
        }
        parent.append( path, position, slash - position );
        struct stat status{};
        if( stat( parent.c_str(), &status ) != 0 || !S_ISDIR( status.st_mode ) || !safeOwner( status.st_uid )
            || ( ( status.st_mode & 0022 ) != 0 && ( status.st_mode & S_ISVTX ) == 0 ) )
        {
            return false;
        }
        position = slash + 1;
    }
    if( lstat( path.c_str(), &endpointStatus ) != 0 || !S_ISSOCK( endpointStatus.st_mode ) || !safeOwner( endpointStatus.st_uid )
        || ( endpointStatus.st_mode & 0022 ) != 0 )
    {
        return false;
    }
    return true;
}

bool validateUnixPeer( const int descriptor ) noexcept
{
#if defined( __APPLE__ ) || defined( __FreeBSD__ )
    uid_t effectiveUser = 0;
    gid_t effectiveGroup = 0;
    return getpeereid( descriptor, &effectiveUser, &effectiveGroup ) == 0 && safeOwner( effectiveUser );
#elif defined( __linux__ ) && defined( SO_PEERCRED )
    struct PeerCredentials
    {
        pid_t processId;
        uid_t uid;
        gid_t gid;
    } credentials{};
    socklen_t length = sizeof( credentials );
    return getsockopt( descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length ) == 0 && safeOwner( credentials.uid );
#else
    (void)descriptor;
    return true;
#endif
}

SocketHandle connectUnix( const Endpoint& endpoint, const Deadline deadline, RedisFailure& failure )
{
    struct stat before{};
    if( endpoint.path.size() >= sizeof( sockaddr_un::sun_path ) || !validateUnixPath( endpoint.path, before ) )
    {
        failure = RedisFailure::Connect;
        return {};
    }
    SocketHandle descriptor( socket( AF_UNIX, SOCK_STREAM, 0 ) );
    if( !descriptor || !setDescriptorFlags( descriptor.get() ) )
    {
        failure = RedisFailure::Connect;
        return {};
    }
#if defined( SO_NOSIGPIPE )
    const int enabled = 1;
    setsockopt( descriptor.get(), SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof( enabled ) );
#endif
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy( address.sun_path, endpoint.path.c_str(), endpoint.path.size() + 1 );
    failure = finishConnect( descriptor.get(), reinterpret_cast<const sockaddr*>( &address ), sizeof( address ), deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    struct stat after{};
    if( !validateUnixPath( endpoint.path, after ) || before.st_dev != after.st_dev || before.st_ino != after.st_ino || !validateUnixPeer( descriptor.get() ) )
    {
        failure = RedisFailure::Connect;
        return {};
    }
    return descriptor;
}

bool charge( ParseContext& context, const std::size_t byteCount ) noexcept
{
    if( byteCount > context.aggregateLimit - std::min( context.aggregateBytes, context.aggregateLimit ) )
    {
        return false;
    }
    context.aggregateBytes += byteCount;
    return true;
}

ParseStatus readLine( ParseContext& context, std::string_view& line )
{
    const std::size_t end = context.input.find( "\r\n", context.position );
    if( end == std::string_view::npos )
    {
        return ParseStatus::NeedMore;
    }
    const std::size_t encodedLength = end + 2 - context.position;
    if( !charge( context, encodedLength ) )
    {
        return ParseStatus::Invalid;
    }
    line = context.input.substr( context.position, end - context.position );
    context.position = end + 2;
    return ParseStatus::Complete;
}

bool parseSigned( const std::string_view text, std::int64_t& value ) noexcept
{
    if( text.empty() || text.front() == '+' )
    {
        return false;
    }
    const bool isNegative = text.front() == '-';
    const std::string_view digits = isNegative ? text.substr( 1 ) : text;
    const std::uint64_t maximum = isNegative ? std::uint64_t( std::numeric_limits<std::int64_t>::max() ) + 1u
                                             : std::uint64_t( std::numeric_limits<std::int64_t>::max() );
    std::uint64_t magnitude = 0;
    if( !parseDecimalMagnitude( digits, maximum, magnitude ) )
    {
        return false;
    }
    if( isNegative && magnitude == maximum )
    {
        value = std::numeric_limits<std::int64_t>::min();
    }
    else
    {
        value = isNegative ? -static_cast<std::int64_t>( magnitude ) : static_cast<std::int64_t>( magnitude );
    }
    return true;
}

ParseStatus parseReply( ParseContext& context, RedisReply& reply, const std::size_t depth )
{
    if( depth > kMaximumReplyDepth || context.position >= context.input.size() )
    {
        return context.position >= context.input.size() ? ParseStatus::NeedMore : ParseStatus::Invalid;
    }
    if( ++context.nodeCount > kMaximumReplyNodes || !charge( context, sizeof( RedisReply ) ) )
    {
        return ParseStatus::Invalid;
    }
    const char prefix = context.input[context.position++];
    if( !charge( context, 1 ) )
    {
        return ParseStatus::Invalid;
    }
    std::string_view line;
    ParseStatus lineStatus = readLine( context, line );
    if( lineStatus != ParseStatus::Complete )
    {
        return lineStatus;
    }
    if( prefix == '+' || prefix == '-' )
    {
        reply.type = prefix == '+' ? RedisReplyType::Simple : RedisReplyType::Error;
        reply.bytes.assign( line );
        return ParseStatus::Complete;
    }
    if( prefix == ':' )
    {
        reply.type = RedisReplyType::Integer;
        return parseSigned( line, reply.integer ) ? ParseStatus::Complete : ParseStatus::Invalid;
    }
    if( prefix != '$' && prefix != '*' )
    {
        return ParseStatus::Invalid;
    }
    std::int64_t length = 0;
    if( !parseSigned( line, length ) || length < -1 )
    {
        return ParseStatus::Invalid;
    }
    if( length == -1 )
    {
        reply.type = RedisReplyType::Nil;
        return ParseStatus::Complete;
    }
    if( prefix == '$' )
    {
        if( static_cast<std::uint64_t>( length ) > kMaximumBulkBytes || !charge( context, static_cast<std::size_t>( length ) + 2 ) )
        {
            return ParseStatus::Invalid;
        }
        const std::size_t byteCount = static_cast<std::size_t>( length );
        if( byteCount > context.input.size() - std::min( context.position, context.input.size() ) || context.input.size() - context.position < byteCount + 2 )
        {
            return ParseStatus::NeedMore;
        }
        if( context.input.substr( context.position + byteCount, 2 ) != "\r\n" )
        {
            return ParseStatus::Invalid;
        }
        reply.type = RedisReplyType::Bulk;
        reply.bytes.assign( context.input.substr( context.position, byteCount ) );
        context.position += byteCount + 2;
        return ParseStatus::Complete;
    }
    if( static_cast<std::uint64_t>( length ) > kMaximumArrayElements )
    {
        return ParseStatus::Invalid;
    }
    const std::size_t elementCount = static_cast<std::size_t>( length );
    if( elementCount > ( context.aggregateLimit - std::min( context.aggregateBytes, context.aggregateLimit ) ) / sizeof( RedisReply ) )
    {
        return ParseStatus::Invalid;
    }
    reply.type = RedisReplyType::Array;
    reply.elements.reserve( elementCount );
    for( std::size_t elementIndex = 0; elementIndex < elementCount; ++elementIndex )
    {
        RedisReply element;
        const ParseStatus status = parseReply( context, element, depth + 1 );
        if( status != ParseStatus::Complete )
        {
            return status;
        }
        reply.elements.push_back( std::move( element ) );
    }
    return ParseStatus::Complete;
}

ParseOutcome parseReplies( const std::string_view input, const std::size_t expectedReplyCount, const std::size_t aggregateLimit )
{
    ParseOutcome outcome;
    ParseContext context{ input, 0, 0, 0, aggregateLimit };
    outcome.replies.reserve( expectedReplyCount );
    for( std::size_t replyIndex = 0; replyIndex < expectedReplyCount; ++replyIndex )
    {
        RedisReply reply;
        const ParseStatus status = parseReply( context, reply, 0 );
        if( status != ParseStatus::Complete )
        {
            outcome.status = status;
            outcome.replies.clear();
            return outcome;
        }
        outcome.replies.push_back( std::move( reply ) );
    }
    outcome.status = context.position == input.size() ? ParseStatus::Complete : ParseStatus::Invalid;
    if( outcome.status != ParseStatus::Complete )
    {
        outcome.replies.clear();
    }
    return outcome;
}

std::string errorCategory( const std::string_view error )
{
    constexpr std::array<std::string_view, 8> categories{ "ERR", "WRONGPASS", "NOAUTH", "BUSY", "NOSCRIPT", "READONLY", "OOM", "MISCONF" };
    for( const std::string_view category : categories )
    {
        if( error == category || ( error.starts_with( category ) && error.size() > category.size() && error[category.size()] == ' ' ) )
        {
            return std::string( category );
        }
    }
    return "ERR";
}

RedisFailure errorFailure( const std::string_view error, const bool authenticating )
{
    if( error.starts_with( "MOVED " ) || error.starts_with( "ASK " ) )
    {
        return RedisFailure::ClusterRedirect;
    }
    if( authenticating || error.starts_with( "NOAUTH" ) || error.starts_with( "WRONGPASS" ) )
    {
        return RedisFailure::Auth;
    }
    return RedisFailure::Server;
}

RedisResult classifiedReplyError( RedisReply reply, const std::string_view endpointClass, const bool authenticating )
{
    const RedisFailure failure = errorFailure( reply.bytes, authenticating );
    RedisResult result = failureResult( failure, endpointClass,
                                        failure == RedisFailure::ClusterRedirect ? std::string_view() : std::string_view( errorCategory( reply.bytes ) ) );
    result.reply = std::move( reply );
    return result;
}

bool appendDecimal( std::string& destination, const std::size_t value )
{
    std::array<char, 32> buffer{};
    const auto result = std::to_chars( buffer.data(), buffer.data() + buffer.size(), value );
    if( result.ec != std::errc() )
    {
        return false;
    }
    destination.append( buffer.data(), result.ptr );
    return true;
}

bool appendCommand( std::string& destination, const std::vector<std::string_view>& arguments )
{
    if( arguments.empty() )
    {
        return false;
    }
    destination.push_back( '*' );
    if( !appendDecimal( destination, arguments.size() ) )
    {
        return false;
    }
    destination += "\r\n";
    for( const std::string_view argument : arguments )
    {
        destination.push_back( '$' );
        if( !appendDecimal( destination, argument.size() ) )
        {
            return false;
        }
        destination += "\r\n";
        destination.append( argument.data(), argument.size() );
        destination += "\r\n";
        if( destination.size() > kMaximumRequestBytes )
        {
            return false;
        }
    }
    return destination.size() <= kMaximumRequestBytes;
}

RedisFailure sendAll( const int descriptor, const std::string_view bytes, const Deadline deadline ) noexcept
{
    std::size_t sent = 0;
    while( sent < bytes.size() )
    {
        if( remainingMilliseconds( deadline ) == 0 )
        {
            return RedisFailure::Timeout;
        }
#if defined( MSG_NOSIGNAL )
        constexpr int sendFlags = MSG_NOSIGNAL;
#else
        constexpr int sendFlags = 0;
#endif
        const ssize_t result = send( descriptor, bytes.data() + sent, bytes.size() - sent, sendFlags );
        if( result > 0 )
        {
            sent += static_cast<std::size_t>( result );
            continue;
        }
        if( result < 0 && errno == EINTR )
        {
            continue;
        }
        if( result < 0 && ( errno == EAGAIN || errno == EWOULDBLOCK ) )
        {
            bool timedOut = false;
            if( !waitForSocket( descriptor, POLLOUT, deadline, timedOut ) )
            {
                return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
            }
            continue;
        }
        return RedisFailure::Connect;
    }
    return RedisFailure::None;
}

struct ReceiveResult
{
    RedisFailure failure = RedisFailure::None;
    std::vector<RedisReply> replies;
};

ReceiveResult receiveReplies( const int descriptor, const std::size_t expectedReplyCount, const Deadline deadline )
{
    ReceiveResult result;
    std::string bytes;
    std::array<char, 64u * 1024u> buffer{};
    while( true )
    {
        const ParseOutcome parsed = parseReplies( bytes, expectedReplyCount, kMaximumAggregateBytes );
        if( parsed.status == ParseStatus::Complete )
        {
            result.replies = parsed.replies;
            return result;
        }
        if( parsed.status == ParseStatus::Invalid || bytes.size() >= kMaximumAggregateBytes )
        {
            result.failure = RedisFailure::Protocol;
            return result;
        }
        bool timedOut = false;
        if( !waitForSocket( descriptor, POLLIN, deadline, timedOut ) )
        {
            result.failure = timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
            return result;
        }
        const ssize_t received = recv( descriptor, buffer.data(), std::min( buffer.size(), kMaximumAggregateBytes - bytes.size() ), 0 );
        if( received > 0 )
        {
            bytes.append( buffer.data(), static_cast<std::size_t>( received ) );
            continue;
        }
        if( received < 0 && errno == EINTR )
        {
            continue;
        }
        if( received < 0 && ( errno == EAGAIN || errno == EWOULDBLOCK ) )
        {
            continue;
        }
        result.failure = bytes.empty() ? RedisFailure::Connect : RedisFailure::Protocol;
        return result;
    }
}

}

RedisClient::RedisClient( RedisCacheConfig config ) : config_( std::move( config ) ) {}

RedisResult RedisClient::command( const std::vector<std::string_view>& arguments ) const
{
    return execute( { arguments } );
}

RedisResult RedisClient::pipeline( const std::vector<std::vector<std::string>>& commands ) const
{
    std::vector<std::vector<std::string_view>> views;
    views.reserve( commands.size() );
    for( const std::vector<std::string>& command : commands )
    {
        std::vector<std::string_view> arguments;
        arguments.reserve( command.size() );
        for( const std::string& argument : command )
        {
            arguments.push_back( argument );
        }
        views.push_back( std::move( arguments ) );
    }
    return execute( views );
}

RedisResult RedisClient::execute( const std::vector<std::vector<std::string_view>>& commands ) const
{
    Endpoint endpoint;
    const EndpointKind diagnosticKind = config_.endpoint.starts_with( "redis+unix://" ) ? EndpointKind::Unix : EndpointKind::Tcp;
    const std::string endpointClass = endpointName( diagnosticKind );
    if( config_.timeoutMs == 0 || commands.empty() || commands.size() > kMaximumPipelineCommands || !parseEndpoint( config_.endpoint, endpoint )
        || ( config_.username.empty() && !config_.password.empty() && config_.password.size() > kMaximumRequestBytes )
        || ( !config_.username.empty() && config_.password.empty() ) )
    {
        return failureResult( RedisFailure::Config, endpointClass );
    }

    std::vector<std::vector<std::string_view>> requests;
    requests.reserve( commands.size() + 2 );
    std::vector<std::string_view> authentication;
    if( !config_.password.empty() )
    {
        authentication.push_back( "AUTH" );
        if( !config_.username.empty() )
        {
            authentication.push_back( config_.username );
        }
        authentication.push_back( config_.password );
        requests.push_back( authentication );
    }
    const std::string database = std::to_string( endpoint.database );
    if( endpoint.database != 0 )
    {
        requests.push_back( { "SELECT", database } );
    }
    requests.insert( requests.end(), commands.begin(), commands.end() );

    std::string encoded;
    encoded.reserve( std::min<std::size_t>( 4096, kMaximumRequestBytes ) );
    for( const std::vector<std::string_view>& request : requests )
    {
        if( !appendCommand( encoded, request ) )
        {
            return failureResult( RedisFailure::Config, endpointClass );
        }
    }

    const Deadline deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( config_.timeoutMs );
    RedisFailure connectFailure = RedisFailure::Connect;
    SocketHandle socket = endpoint.kind == EndpointKind::Tcp ? connectTcp( endpoint, config_.allowPlaintextRemote, deadline, connectFailure )
                                                              : connectUnix( endpoint, deadline, connectFailure );
    if( !socket )
    {
        return failureResult( connectFailure, endpointClass );
    }
    const RedisFailure sendFailure = sendAll( socket.get(), encoded, deadline );
    if( sendFailure != RedisFailure::None )
    {
        return failureResult( sendFailure, endpointClass );
    }
    ReceiveResult received = receiveReplies( socket.get(), requests.size(), deadline );
    if( received.failure != RedisFailure::None )
    {
        return failureResult( received.failure, endpointClass );
    }

    std::size_t responseIndex = 0;
    if( !config_.password.empty() )
    {
        RedisReply& authenticationReply = received.replies[responseIndex++];
        if( authenticationReply.type == RedisReplyType::Error )
        {
            return classifiedReplyError( std::move( authenticationReply ), endpointClass, true );
        }
        if( authenticationReply.type != RedisReplyType::Simple || authenticationReply.bytes != "OK" )
        {
            return failureResult( RedisFailure::Protocol, endpointClass );
        }
    }
    if( endpoint.database != 0 )
    {
        RedisReply& selectionReply = received.replies[responseIndex++];
        if( selectionReply.type == RedisReplyType::Error )
        {
            return classifiedReplyError( std::move( selectionReply ), endpointClass, false );
        }
        if( selectionReply.type != RedisReplyType::Simple || selectionReply.bytes != "OK" )
        {
            return failureResult( RedisFailure::Protocol, endpointClass );
        }
    }
    for( std::size_t replyIndex = responseIndex; replyIndex < received.replies.size(); ++replyIndex )
    {
        if( received.replies[replyIndex].type == RedisReplyType::Error )
        {
            return classifiedReplyError( std::move( received.replies[replyIndex] ), endpointClass, false );
        }
    }
    RedisResult result;
    if( commands.size() == 1 )
    {
        result.reply = std::move( received.replies[responseIndex] );
    }
    else
    {
        result.reply.type = RedisReplyType::Array;
        result.reply.elements.reserve( commands.size() );
        for( std::size_t replyIndex = responseIndex; replyIndex < received.replies.size(); ++replyIndex )
        {
            result.reply.elements.push_back( std::move( received.replies[replyIndex] ) );
        }
    }
    return result;
}

RedisResult RedisClient::parseReplyForTesting( const std::string_view bytes, const std::size_t aggregateLimit )
{
    ParseOutcome parsed = parseReplies( bytes, 1, aggregateLimit );
    if( parsed.status != ParseStatus::Complete )
    {
        return failureResult( RedisFailure::Protocol, "reply" );
    }
    if( parsed.replies[0].type == RedisReplyType::Error )
    {
        return classifiedReplyError( std::move( parsed.replies[0] ), "reply", false );
    }
    RedisResult result;
    result.reply = std::move( parsed.replies[0] );
    return result;
}

RedisResult RedisClient::parseReplyChunksForTesting( const std::vector<std::string_view>& chunks )
{
    std::string bytes;
    for( std::size_t chunkIndex = 0; chunkIndex < chunks.size(); ++chunkIndex )
    {
        bytes.append( chunks[chunkIndex] );
        const ParseOutcome parsed = parseReplies( bytes, 1, kMaximumAggregateBytes );
        if( chunkIndex + 1 < chunks.size() && parsed.status != ParseStatus::NeedMore )
        {
            return failureResult( RedisFailure::Protocol, "reply" );
        }
    }
    return parseReplyForTesting( bytes );
}

}
