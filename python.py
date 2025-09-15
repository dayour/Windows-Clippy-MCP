#!/usr/bin/env python3
"""
Entry point for Windows Clippy MCP Server
This file serves as the entry point referenced in MCP configuration files.
"""

from main import mcp

if __name__ == "__main__":
    mcp.run()