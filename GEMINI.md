# GEMINI.md - Gazelle 🦌

## Project Overview
**Gazelle** is a modern, high-performance PostgreSQL real-time change watcher built with **Zig (0.16.0)**. It leverages the PostgreSQL Logical Replication protocol to monitor and visualize database changes (`INSERT`, `UPDATE`, `DELETE`) in real-time.

### Main Technologies
- **Language**: Zig 0.16.0
- **Database**: PostgreSQL 14+ (with `wal_level = logical`)
- **Environment**: Nix (for reproducible builds and dependency management)
- **Library Integration**: `libpq` (via Zig's `translate-c`)

### Architecture
- `src/main.zig`: Entry point for the CLI tool, signal handling (SIGINT), and watcher loop.
- `src/root.zig`: Library entry point, re-exporting core modules.
- `src/connection.zig`: Manages the `libpq` connection, replication slots, and publications.
- `src/protocol.zig`: Implements the logical replication protocol parsing (XLogData, Relation, Insert, Update, Delete messages).
- `src/formatter.zig`: Handles output formatting for both human-readable text and JSON Lines.

## Building and Running

### Development Environment
It is highly recommended to use the provided Nix flake to ensure all dependencies (`libpq`, `pkg-config`, `zig`) are correctly configured.
```bash
nix develop
```

### Build Commands
- **Build the project**:
  ```bash
  zig build
  ```
- **Run the application**:
  ```bash
  zig build run -- --dsn "postgresql://user:pass@host:5432/dbname?replication=database"
  ```
- **Run tests**:
  ```bash
  zig build test
  ```

## Development Conventions

### Module Naming
The project is identified as the `gazelle` module. Always use `@import("gazelle")` for internal and external module references as configured in `build.zig`.

### Coding Standards
- **Memory Management**: Prioritize explicit allocator usage. Use `std.heap.ArenaAllocator` for per-message processing loops to avoid leaks.
- **Error Handling**: Use Zig's error union patterns. Reconnection logic must implement exponential backoff (see `Watcher.run` in `src/main.zig`).
- **Signal Safety**: Graceful shutdown on `SIGINT` is mandatory. The application uses atomic flags to signal the main loop to exit and clean up replication resources.
- **Logical Replication**: Always ensure `replication=database` is present in the DSN.

### Testing
Add unit tests within the relevant source files or in separate test blocks. Ensure `zig build test` passes before committing changes.

## Development Workflow
- **Agent Context**: Additional project-specific notes, design documents, or research materials that should not be committed to Git can be placed in the `.gemini/` directory. The agent should check this directory for supplemental context when needed.
- **Environment**: Always work within the `nix develop` shell or ensure `libpq` is available in the library path.

