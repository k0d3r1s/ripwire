#include "editpreview.h"   // the same pre-apply declarations supplied before mcp.h by main.cpp
#include "mcp.h"

// Exercise the source-compatible API default, without CLI cache-policy resolution.
int main()
{
    return rw::runMcp( 200 );
}
