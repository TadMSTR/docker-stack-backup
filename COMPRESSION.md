# Compression Configuration Guide

The backup scripts support multiple compression methods with configurable levels and parallel processing options.

## Quick Reference

```bash
# In docker-stack-backup.sh or docker-stack-backup-manual.sh

# Compression Configuration
COMPRESSION_METHOD="gzip"    # gzip, bzip2, xz, zstd, none
COMPRESSION_LEVEL=6          # 1-9 (1=fast, 9=best compression)
USE_PARALLEL=false           # Enable multi-threaded compression
PARALLEL_THREADS=0           # 0=auto, or specify (e.g., 4)
EXCLUDE_PATTERNS=(           # Skip files/directories
    # "*/cache/*"
    # "*/tmp/*"
    # "*.log"
)
```

---

## Compression Methods

### gzip (Default)
**Best for:** General use, maximum compatibility

```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=6
```

**Characteristics:**
- File extension: `.tar.gz`
- Speed: Fast
- Compression ratio: Good
- CPU usage: Low
- Compatibility: Universal
- Parallel tool: `pigz` (install: `apt-get install pigz`)

**When to use:**
- Default choice for most situations
- Need wide compatibility
- Moderate-sized appdata (< 50GB)

**Compression levels:**
- `1` - Fastest, larger files (~3-5x original size)
- `6` - Default, good balance (~5-8x original size)
- `9` - Best compression, slower (~6-10x original size)

---

### bzip2
**Best for:** Better compression than gzip, still widely supported

```bash
COMPRESSION_METHOD="bzip2"
COMPRESSION_LEVEL=9
```

**Characteristics:**
- File extension: `.tar.bz2`
- Speed: Slower than gzip
- Compression ratio: Better than gzip
- CPU usage: Moderate
- Compatibility: Very good
- Parallel tool: `pbzip2` (install: `apt-get install pbzip2`)

**When to use:**
- Storage space is limited
- Willing to trade time for space
- Text-heavy appdata (logs, configs)

**Typical results:**
- 10-20% smaller than gzip at same level
- 2-3x slower than gzip

---

### xz
**Best for:** Maximum compression, long-term archival

```bash
COMPRESSION_METHOD="xz"
COMPRESSION_LEVEL=6
```

**Characteristics:**
- File extension: `.tar.xz`
- Speed: Slowest
- Compression ratio: Best
- CPU usage: High
- Memory usage: Can be very high
- Compatibility: Good (requires xz-utils)
- Parallel tool: `pxz` (install: `apt-get install pxz`)

**When to use:**
- Archival backups (long-term storage)
- Storage space at premium
- Backup window is not critical
- Large databases or media files

**Typical results:**
- 20-40% smaller than gzip
- 5-10x slower than gzip
- Can use 700MB+ RAM per thread

**Warning:** Level 9 uses massive amounts of RAM (up to 674MB per thread)

---

### zstd (Modern)
**Best for:** Balance of speed and compression with modern features

```bash
COMPRESSION_METHOD="zstd"
COMPRESSION_LEVEL=3
```

**Characteristics:**
- File extension: `.tar.zst`
- Speed: Fast (faster than gzip)
- Compression ratio: Good (similar to gzip)
- CPU usage: Moderate
- Compatibility: Requires `zstd` package
- Parallel: Built-in multi-threading

**When to use:**
- Modern systems with zstd support
- Want speed with good compression
- Large backups with tight windows

**Typical results:**
- Similar compression to gzip
- 2-3x faster than gzip
- Excellent scaling on multi-core

**Note:** Not as universally supported as gzip/bzip2

---

### none
**Best for:** Speed over everything, or pre-compressed data

```bash
COMPRESSION_METHOD="none"
```

**Characteristics:**
- File extension: `.tar`
- Speed: Fastest
- Compression ratio: None (1:1)
- CPU usage: Minimal

**When to use:**
- Data already compressed (videos, images)
- Network backup over fast LAN
- Compression will happen elsewhere
- Maximum speed required

---

## Parallel Compression

Significantly speeds up compression on multi-core systems.

### Setup

```bash
USE_PARALLEL=true
PARALLEL_THREADS=4    # Or 0 for auto-detect
```

### Install Parallel Tools

```bash
# For gzip (pigz)
apt-get install pigz

# For bzip2 (pbzip2)
apt-get install pbzip2

# For xz (pxz)
apt-get install pxz

# zstd has built-in parallel support
apt-get install zstd
```

### Performance Comparison

**Example: 10GB appdata, 4-core CPU**

| Method | Standard | Parallel | Speedup |
|--------|----------|----------|---------|
| gzip   | 120s     | 35s      | 3.4x    |
| bzip2  | 280s     | 75s      | 3.7x    |
| xz     | 450s     | 125s     | 3.6x    |
| zstd   | 90s      | 25s      | 3.6x    |

**CPU Usage:**
- Standard: ~100% (single core)
- Parallel: ~400% (4 cores)

### Auto-detect Cores

```bash
PARALLEL_THREADS=0
```

Script automatically uses all available cores:
```bash
# Detection happens internally
nproc  # Returns number of processors
```

---

## Exclude Patterns

Skip files/directories that don't need backup:

```bash
EXCLUDE_PATTERNS=(
    "*/cache/*"           # Cache directories
    "*/tmp/*"             # Temporary files
    "*.log"               # Log files
    "*/Trash/*"           # Trash folders
    "*/.Trash-*/*"        # Linux trash
    "*/thumbnails/*"      # Thumbnail caches
    "*/__pycache__/*"     # Python cache
    "*/node_modules/*"    # Node.js modules (if applicable)
)
```

**Pattern syntax:**
- `*` - Matches any characters
- `*/cache/*` - Matches any `cache` directory
- `*.log` - Matches files ending in `.log`
- Patterns are relative to appdata directory

**Benefits:**
- Faster backups
- Smaller archives
- Less restore time
- Skip regeneratable data

---

## Configuration Examples

### Fast Daily Backups (Home Lab)
```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=1          # Speed over size
USE_PARALLEL=true
PARALLEL_THREADS=0           # Use all cores
EXCLUDE_PATTERNS=(
    "*/cache/*"
    "*/tmp/*"
    "*.log"
)
```

### Balanced Production
```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=6          # Default balance
USE_PARALLEL=true
PARALLEL_THREADS=4
EXCLUDE_PATTERNS=(
    "*/cache/*"
    "*/tmp/*"
)
```

### Maximum Compression (Archival)
```bash
COMPRESSION_METHOD="xz"
COMPRESSION_LEVEL=9          # Best compression
USE_PARALLEL=true
PARALLEL_THREADS=4
EXCLUDE_PATTERNS=(
    "*/cache/*"
    "*/tmp/*"
    "*.log"
    "*/thumbnails/*"
)
```

### Fast Modern Systems
```bash
COMPRESSION_METHOD="zstd"
COMPRESSION_LEVEL=3
USE_PARALLEL=true            # Built-in
PARALLEL_THREADS=0
EXCLUDE_PATTERNS=(
    "*/cache/*"
)
```

### NAS to NAS (No Compression)
```bash
COMPRESSION_METHOD="none"
# Fast local backups, compress later if needed
```

---

## Choosing the Right Settings

### By Use Case

**Daily automated backups:**
- Method: `gzip` or `zstd`
- Level: `3-6`
- Parallel: `true`

**Weekly full backups:**
- Method: `gzip` or `bzip2`
- Level: `6-9`
- Parallel: `true`

**Monthly archival:**
- Method: `xz`
- Level: `6-9`
- Parallel: `true` (if RAM allows)

**Pre-migration backup:**
- Method: `gzip`
- Level: `6`
- Parallel: `true`

### By Backup Window

**< 5 minutes available:**
```bash
COMPRESSION_METHOD="zstd"
COMPRESSION_LEVEL=1
USE_PARALLEL=true
```

**5-30 minutes available:**
```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=6
USE_PARALLEL=true
```

**Hours available (overnight):**
```bash
COMPRESSION_METHOD="xz"
COMPRESSION_LEVEL=9
USE_PARALLEL=true
```

### By Storage Constraints

**Storage abundant:**
```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=3
```

**Storage limited:**
```bash
COMPRESSION_METHOD="xz"
COMPRESSION_LEVEL=9
```

**Network backup (bandwidth limited):**
```bash
COMPRESSION_METHOD="xz"
COMPRESSION_LEVEL=6
# Smaller files = faster transfer
```

---

## Testing Compression Settings

Test different settings to find optimal balance:

```bash
# Create test backup of one stack
cd /mnt/datastor/appdata

# Test gzip levels
time tar -cz1f test-1.tar.gz stack-name  # Level 1
time tar -cz6f test-6.tar.gz stack-name  # Level 6
time tar -cz9f test-9.tar.gz stack-name  # Level 9

# Compare
ls -lh test-*.tar.gz

# Cleanup
rm test-*.tar.gz
```

**Check results:**
```bash
# Size vs time tradeoff
du -h test-*.tar.gz
```

---

## Troubleshooting

### Compression is very slow
- Lower `COMPRESSION_LEVEL`
- Enable `USE_PARALLEL=true`
- Switch to faster method (`zstd` or `gzip`)
- Check CPU usage: `top`

### Out of memory errors
- Lower `COMPRESSION_LEVEL` (especially for xz)
- Reduce `PARALLEL_THREADS`
- Switch to lower-memory method (`gzip`)

### Parallel tools not working
```bash
# Install missing tools
apt-get install pigz pbzip2 pxz zstd

# Verify installation
which pigz pbzip2 pxz zstd
```

### Backup files not recognized
- Some tools require specific compression utilities
- Ensure target system has appropriate tools installed
- Use `gzip` for maximum compatibility

### Pattern excludes not working
```bash
# Test exclude patterns
tar -czf test.tar.gz --exclude="*.log" --exclude="*/cache/*" /path/to/test

# List contents to verify
tar -tzf test.tar.gz | grep -E '\.log|/cache/'  # Should be empty
```

---

## Recommendations

**Start with defaults:**
```bash
COMPRESSION_METHOD="gzip"
COMPRESSION_LEVEL=6
USE_PARALLEL=true
PARALLEL_THREADS=0
```

**Then optimize based on:**
1. Backup window duration
2. Available storage
3. CPU/RAM resources
4. Restore time requirements

**Monitor and adjust:**
- Check backup logs for timing
- Measure archive sizes
- Test restore speed
- Adjust as needed

**Best practice:**
- Same compression across all hosts
- Document your settings
- Test restores regularly
- Balance speed, size, and compatibility
