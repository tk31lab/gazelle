# Project Gazelle 🦌

A modern, high-performance PostgreSQL real-time change watcher built with **Zig (0.16.0)**. 
Gazelle leverages the PostgreSQL Logical Replication protocol to monitor and visualize database changes (`INSERT`, `UPDATE`, `DELETE`) in real-time.

![Zig Version](https://img.shields.io/badge/Zig-0.16.0-orange.svg)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%2B-blue.svg)

## ✨ Features

- **Real-time Monitoring**: Stream changes directly from PostgreSQL WAL using logical replication.
- **Rich Visualization**: ANSI-colored output for human readability, highlighting differences in `UPDATE` operations.
- **JSON Lines Support**: Machine-readable output via the `--json` flag for integration with logging pipelines (ELK, CloudWatch, etc.).
- **Robust Reconnection**: Automatic recovery from network issues or database restarts using **exponential backoff**.
- **Self-Configuring**: Automatically ensures `PUBLICATION` exists and sets `REPLICA IDENTITY FULL` for all tables on startup.
- **Zero-Dependency CLI**: Single binary (requires `libpq`) with flexible configuration via CLI arguments.
- **Graceful Shutdown**: Properly cleans up replication slots on `SIGINT` (Ctrl+C).

## 🚀 Getting Started

### Prerequisites

- **Zig 0.16.0**
- **libpq** (PostgreSQL client library)
- **PostgreSQL 14+** (with `wal_level = logical`)

### Quick Start

1. **Run Gazelle**:
   ```bash
   zig build run -- --dsn "postgresql://postgres:password@localhost:5432/gazelle_db?replication=database"
   ```

2. **See it in Action**:
   Open another terminal and run some SQL to see real-time changes:
   ```bash
   psql -U postgres -d gazelle_db -c "INSERT INTO users (name) VALUES ('ZigDeveloper');"
   ```

## 🛠 Usage & Configuration

### Command Line Options

| Option | Description | Default |
| :--- | :--- | :--- |
| `--dsn <dsn>` | PostgreSQL connection string (URI or Key-Value) | `host=localhost ...` |
| `--slot <name>` | Replication slot name | `gazelle_slot` |
| `--pub <name>` | Publication name | `gazelle_pub` |
| `--json` | Enable JSON Lines output format | (Text mode) |
| `-h, --help` | Show help message | - |

### DSN Examples

Gazelle supports all `libpq` connection string formats:

- **URI Format (Recommended)**:
  `"postgresql://user:pass@host:5432/dbname?replication=database"`
- **Key-Value Format**:
  `"host=localhost port=5432 user=postgres dbname=gazelle_db replication=database"`
- **Unix Domain Socket**:
  `"host=/tmp dbname=gazelle_db replication=database"`

> **Note**: `replication=database` parameter is mandatory for logical replication.

## 🏗 Architecture

Gazelle is built with a focus on reliability and modern Zig paradigms:
- **Juicy Main**: Utilizes the Zig 0.16.0 `std.process.Init` for clean dependency injection and IO management.
- **Watcher Pattern**: Separates application state and connection logic from the main loop.
- **Atomic Signal Handling**: Thread-safe interruption handling for clean resource deallocation.

## 📜 License

MIT License
