# Pegasus Multimedia Platform - Practical Developer Guide

**Version:** 1.0  
**Last Updated:** May 2026  
**Target Audience:** Software developers working with HiSilicon SS928V100/SS927V100 multimedia processing

---

## 📋 Table of Contents

1. [Quick Start](#quick-start)
2. [Project Overview](#project-overview)
3. [Environment Setup](#environment-setup)
4. [Development Workflow](#development-workflow)
5. [Building & Compilation](#building--compilation)
6. [Testing & Debugging](#testing--debugging)
7. [Common Tasks](#common-tasks)
8. [Troubleshooting](#troubleshooting)
9. [Best Practices](#best-practices)
10. [Contributing Guidelines](#contributing-guidelines)

---

## 🚀 Quick Start

### 5-Minute Setup (Docker)

```bash
# Clone the repository
git clone https://gitee.com/HiSpark/pegasus.git
cd pegasus

# Build Docker image
docker build -t pegasus:dev .

# Run development container
docker-compose up -d pegasus-dev

# Enter the container
docker-compose exec pegasus-dev bash

# Setup environment
build-helper.sh setup

# Build with GCC toolchain
build-helper.sh build-gcc
```

### Without Docker (Linux/Ubuntu 22.04+)

```bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y build-essential cmake git python3-pip \
    libssl-dev libncurses-dev zlib1g-dev

# Clone and prepare
git clone https://gitee.com/HiSpark/pegasus.git
cd pegasus

# Initialize submodules
git submodule init
git submodule update platform/ss928v100_gcc

# Build
cd platform/ss928v100_gcc/osdrv
make
```

---

## 📚 Project Overview

### What is Pegasus?

Pegasus is a multimedia processing platform supporting HiSilicon SS928V100/SS927V100 chips. It provides:

- **Audio/Video Capture** - Input from various sources
- **Encoding/Decoding** - Hardware-accelerated codec support
- **Video Processing** - Pre-processing, enhancement, and effects
- **Output** - Display and streaming capabilities
- **Logging System** - Comprehensive debugging and monitoring
- **OpenHarmony Integration** - RTOS support for embedded systems

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Application Layer                          │
├─────────────────────────────────────────────────────────────┤
│                   OpenHarmony (RTOS)                        │
├─────────────────────────────────────────────────────────────┤
│  Audio/Video Codecs │ Processing │ Input/Output │ Logging   │
├─────────────────────────────────────────────────────────────┤
│  HiSilicon Linux Kernel (6.6) & Drivers                    │
├─────────────────────────────────────────────────────────────┤
│         SS928V100 / SS927V100 Hardware                      │
└─────────────────────────────────────────────────────────────┘
```

### Directory Structure

```
pegasus/
├── docs/                        # Documentation (Chinese, PDF guides)
│   └── zh-CN/                   # Installation guides, API references
├── os/                          # Operating system integration
│   └── OpenHarmony/             # OpenHarmony 5.1.0 patches
│       ├── device/              # Device configuration
│       ├── kernel/              # Linux kernel 6.6 config
│       └── vendor/              # Vendor-specific configs
├── platform/                    # SDKs & Toolchains
│   ├── ss928v100_clang/         # CLANG-MUSL SDK (LLVM 15.04)
│   │   ├── open_source/         # Build dependencies
│   │   ├── osdrv/               # Kernel & bootloader
│   │   └── smp/                 # Sample code & drivers
│   └── ss928v100_gcc/           # GCC-GLIBC SDK (GCC 12.3.0)
│       ├── open_source/
│       ├── osdrv/
│       └── smp/
├── tools/                       # Development utilities
├── vendor/                      # Third-party patches & configs
├── Dockerfile                   # Container definition
├── docker-compose.yml           # Multi-container setup
└── build-helper.sh              # Build automation script
```

---

## 🔧 Environment Setup

### Option 1: Docker (Recommended for Isolation)

**Advantages:**
- Consistent environment across machines
- No system pollution
- Easy cleanup

**Prerequisites:**
- Docker 20.10+
- Docker Compose 2.0+ (optional but recommended)

**Setup:**

```bash
# Build image
docker build -t pegasus:dev .

# Run container
docker run -it --name pegasus-dev \
  -v $(pwd):/workspace/pegasus \
  pegasus:dev bash

# Or use Docker Compose
docker-compose up -d pegasus-dev
docker-compose exec pegasus-dev bash
```

**Environment variables inside container:**
```bash
export PEGASUS_ROOT=/workspace/pegasus
export SDK_TYPE=gcc  # or 'clang'
export BUILD_DIR=/workspace/pegasus/build
export VERBOSE=1    # for detailed build output
```

### Option 2: Native Linux Setup

**System Requirements:**
- Ubuntu 20.04 LTS or later (22.04 LTS recommended)
- 4+ CPU cores
- 8+ GB RAM
- 50+ GB disk space

**Install Dependencies:**

```bash
# Update package manager
sudo apt-get update && sudo apt-get upgrade -y

# Install build tools
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    pkg-config \
    autoconf \
    automake \
    libtool \
    bison \
    flex \
    python3-dev \
    python3-pip

# Install library dependencies
sudo apt-get install -y \
    libssl-dev \
    libncurses-dev \
    libreadline-dev \
    zlib1g-dev

# Install cross-compilation support
sudo apt-get install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    device-tree-compiler

# Install Python packages
pip3 install pyyaml pycryptodomex
```

**Configure Environment:**

```bash
# Add to ~/.bashrc or ~/.zshrc
export PEGASUS_ROOT=~/pegasus
export SDK_TYPE=gcc
export BUILD_DIR=$PEGASUS_ROOT/build
export PATH=$PEGASUS_ROOT/tools/bin:$PATH

# Source the file
source ~/.bashrc
```

### Option 3: macOS Setup (Cross-compilation)

```bash
# Install Homebrew dependencies
brew install cmake git python3 gcc@12 binutils

# Use Docker for actual builds (recommended)
docker pull ubuntu:22.04
# Then use Option 1 above
```

---

## 💻 Development Workflow

### Daily Development Cycle

```
1. Fetch Updates
   └─> git pull origin main
       git submodule update

2. Create Feature Branch
   └─> git checkout -b feature/your-feature-name

3. Code Changes
   └─> Edit source files
       Update tests
       Check formatting

4. Build & Test
   └─> build-helper.sh build-gcc
       ./run_tests.sh

5. Commit & Push
   └─> git add .
       git commit -m "feat: description"
       git push origin feature/your-feature-name

6. Create Pull Request
   └─> On Gitee: Compare and pull request
```

### Cloning with Submodules

```bash
# Full clone with submodules
git clone --recursive https://gitee.com/HiSpark/pegasus.git

# Or if already cloned
cd pegasus
git submodule init
git submodule update

# Clone specific SDK
git submodule update platform/ss928v100_gcc

# Clone both SDKs
git submodule update platform/ss928v100_clang platform/ss928v100_gcc
```

### Branch Naming Convention

Follow this pattern for consistency:

```
feature/description      - New features
fix/description         - Bug fixes
docs/description        - Documentation
refactor/description    - Code refactoring
test/description        - Tests and test infrastructure
perf/description        - Performance improvements
ci/description          - CI/CD changes
```

Example: `feature/audio-codec-optimization`

---

## 🔨 Building & Compilation

### Using Build Helper Script

The `build-helper.sh` script simplifies common tasks:

```bash
# Show available commands
./build-helper.sh help

# Setup development environment
./build-helper.sh setup

# Build with GCC-GLIBC (GCC 12.3.0, GLIBC 2.38)
./build-helper.sh build-gcc

# Build with CLANG-MUSL (LLVM 15.04, MUSL 1.2.5)
./build-helper.sh build-clang

# Clean build artifacts
./build-helper.sh clean

# Show environment status
./build-helper.sh env

# Enter interactive shell
./build-helper.sh shell
```

### Direct Make Commands

```bash
# Build GCC SDK
cd platform/ss928v100_gcc/osdrv
make VERBOSE=1

# Build specific component
make -C smp/a55_linux/mpp component=codec

# Clean build
make clean

# Show available targets
make help
```

### Compile Flags & Options

**Common Environment Variables:**

```bash
# Toolchain selection
export CC=gcc                 # or 'clang'
export CXX=g++               # or 'clang++'

# Optimization levels
export CFLAGS="-O2 -Wall"    # Production
export CFLAGS="-O0 -g"       # Debug (no optimization)

# Architecture-specific
export ARCH=arm              # Target architecture
export CROSS_COMPILE=arm-linux-gnueabihf-

# Build options
export VERBOSE=1             # Verbose output
export JOBS=4                # Parallel jobs
```

### Build Profiles

**Debug Build:**
```bash
export CFLAGS="-O0 -g -DDEBUG"
export CXXFLAGS="-O0 -g -DDEBUG"
./build-helper.sh build-gcc
```

**Release Build:**
```bash
export CFLAGS="-O2 -DNDEBUG"
export CXXFLAGS="-O2 -DNDEBUG"
./build-helper.sh build-gcc
```

**Minimal Build (embedded):**
```bash
export CFLAGS="-Os -DMINIMAL"
./build-helper.sh build-gcc
```

---

## 🧪 Testing & Debugging

### Running Tests

```bash
# Run all tests
./build-helper.sh test

# Run specific test suite
cd platform/ss928v100_gcc/smp/a55_linux/test
./run_tests.sh --suite=codec

# Run with coverage
make test COVERAGE=1
```

### Debugging with GDB

```bash
# Build with debug symbols
export CFLAGS="-O0 -g"
./build-helper.sh build-gcc

# Run with GDB
gdb ./build/gcc/bin/pegasus-app
(gdb) break main
(gdb) run
(gdb) step
(gdb) print variable_name
(gdb) continue
```

### Logging & Trace Output

```bash
# Enable verbose logging
export LOG_LEVEL=DEBUG
./build/gcc/bin/pegasus-app

# Save logs to file
./build/gcc/bin/pegasus-app > pegasus.log 2>&1
tail -f pegasus.log

# Filter specific component
grep "codec" pegasus.log
grep "ERROR" pegasus.log
```

### Memory Debugging

```bash
# Use valgrind to check memory leaks
valgrind --leak-check=full \
    --show-leak-kinds=all \
    ./build/gcc/bin/pegasus-app

# Profile memory usage
valgrind --tool=massif ./build/gcc/bin/pegasus-app
ms_print massif.out.* > profile.txt
```

---

## 📝 Common Tasks

### Adding a New Module

```bash
# 1. Create module directory
mkdir -p platform/ss928v100_gcc/smp/a55_linux/mpp/component/my_module

# 2. Create Makefile
cat > platform/ss928v100_gcc/smp/a55_linux/mpp/component/my_module/Makefile << 'EOF'
MODULE := my_module
SRCS := $(wildcard *.c)
OBJS := $(SRCS:.c=.o)
LDFLAGS := -shared

all: lib$(MODULE).so

lib$(MODULE).so: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

clean:
	rm -f $(OBJS) lib$(MODULE).so

.PHONY: all clean
EOF

# 3. Create source files
cat > platform/ss928v100_gcc/smp/a55_linux/mpp/component/my_module/my_module.c << 'EOF'
#include <stdio.h>
#include "my_module.h"

void my_function(void) {
    printf("My module function\n");
}
EOF

# 4. Build
cd platform/ss928v100_gcc/osdrv
make -C smp/a55_linux/mpp/component/my_module
```

### Applying Patches

```bash
# List available patches
ls os/OpenHarmony/device/soc/hisilicon/patches/

# Apply single patch
patch -p1 < os/OpenHarmony/device/soc/hisilicon/patches/fix-name.patch

# Apply all patches
for patch in os/OpenHarmony/device/soc/hisilicon/patches/*.patch; do
    patch -p1 < "$patch" || echo "Failed to apply $patch"
done
```

### Updating Dependencies

```bash
# Check for outdated packages
cd platform/ss928v100_gcc/open_source/
for dir in */; do
    echo "Checking $dir"
    # Check latest version on upstream
done

# Update specific dependency
cd platform/ss928v100_gcc/open_source/openssl
./configure --prefix=$(pwd)/install
make && make install
```

### Creating Release Builds

```bash
# 1. Tag version
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# 2. Build release artifacts
./build-helper.sh clean
export CFLAGS="-O2 -DNDEBUG"
./build-helper.sh build-gcc
./build-helper.sh build-clang

# 3. Package artifacts
mkdir -p release/v1.0.0
cp -r build/gcc/bin release/v1.0.0/gcc-bin
cp -r build/clang/bin release/v1.0.0/clang-bin
tar -czf pegasus-v1.0.0.tar.gz release/

# 4. Generate checksums
cd release/v1.0.0
sha256sum * > checksums.txt
```

---

## 🔍 Troubleshooting

### Build Failures

**Problem:** "Command not found: gcc"

```bash
# Solution 1: Install GCC
sudo apt-get install build-essential

# Solution 2: Update PATH
export PATH=/usr/bin:$PATH

# Solution 3: Use Docker
docker-compose up -d pegasus-dev
```

**Problem:** "Missing library: libssl-dev"

```bash
# Solution: Install missing dependencies
sudo apt-get install libssl-dev libncurses-dev zlib1g-dev

# Or in Docker: rebuild image
docker build --no-cache -t pegasus:dev .
```

**Problem:** "Permission denied" when accessing /opt

```bash
# Solution: Use Docker with proper permissions
docker-compose up -d pegasus-dev
# Inside container, files are owned by pegasus user
```

### Submodule Issues

**Problem:** "fatal: No submodule mapping found in .gitmodules"

```bash
# Solution: Properly initialize submodules
git submodule init
git submodule update --init --recursive

# Or clone with submodules initially
git clone --recursive https://gitee.com/HiSpark/pegasus.git
```

**Problem:** "working tree dirty" when switching branches

```bash
# Solution: Commit submodule changes
git add platform/ss928v100_gcc
git commit -m "Update submodule"

# Or stash changes
git stash
```

### Docker Issues

**Problem:** "Cannot connect to Docker daemon"

```bash
# Solution: Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Or add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

**Problem:** "Disk space issues"

```bash
# Clean up Docker
docker system prune -a

# Check sizes
docker system df
```

### Compilation Errors

**Problem:** "undefined reference to 'function'"

```bash
# Solution: Check library linking
# Add to LDFLAGS in Makefile
LDFLAGS = -L/path/to/lib -lmylib

# Verify library exists
find . -name "libmylib.a" -o -name "libmylib.so"
```

**Problem:** "error: conflicting types for function"

```bash
# Solution: Check header files
# Verify function declaration matches definition
grep "function_name" *.h
gcc -Werror=strict-prototypes -c file.c  # Enable strict checking
```

---

## ✅ Best Practices

### Code Quality

1. **Follow Coding Standards**
   - Use consistent indentation (4 spaces)
   - Meaningful variable and function names
   - Document complex logic with comments

2. **Static Analysis**
   ```bash
   # Check code with cppcheck
   cppcheck --enable=all platform/ss928v100_gcc/smp/

   # Use compiler warnings
   export CFLAGS="-Wall -Wextra -Werror"
   ```

3. **Version Control**
   - Write clear commit messages
   - One logical change per commit
   - Keep history clean and linear

### Testing Strategy

1. **Unit Tests**
   - Test individual components
   - Mock external dependencies
   - Run before commit

2. **Integration Tests**
   - Test component interactions
   - Use real hardware when possible
   - Validate data flow

3. **Regression Tests**
   - Prevent regressions
   - Run full suite before release
   - Document expected outputs

### Performance Optimization

1. **Profiling**
   ```bash
   # Use perf for CPU profiling
   perf record -g ./build/gcc/bin/pegasus-app
   perf report

   # Memory profiling
   valgrind --tool=massif ./build/gcc/bin/pegasus-app
   ```

2. **Optimization Checklist**
   - ✓ Use appropriate optimization flags (-O2, -O3)
   - ✓ Minimize memory allocations in tight loops
   - ✓ Use hardware acceleration when available
   - ✓ Profile before and after changes

### Documentation

1. **Code Comments**
   ```c
   /**
    * @brief Process audio frame
    * @param frame Input audio frame
    * @param length Frame length in samples
    * @return Status code (0 = success)
    */
   int process_audio_frame(audio_frame_t *frame, int length);
   ```

2. **Documentation Files**
   - Update docs/ when adding features
   - Keep README.md current
   - Document API changes

---

## 🤝 Contributing Guidelines

### Before Contributing

1. **Fork & Clone**
   ```bash
   git clone https://gitee.com/your-username/pegasus.git
   cd pegasus
   ```

2. **Create Feature Branch**
   ```bash
   git checkout -b feature/your-feature
   ```

3. **Set Up Development**
   ```bash
   ./build-helper.sh setup
   ```

### Submitting Changes

1. **Code Changes**
   - Follow coding standards (see Best Practices)
   - Write meaningful commit messages
   - Add tests for new features
   - Update documentation

2. **Testing Locally**
   ```bash
   # Build both toolchains
   ./build-helper.sh build-gcc
   ./build-helper.sh build-clang

   # Run tests
   ./build-helper.sh test

   # Check for issues
   cppcheck platform/ss928v100_gcc/smp/
   ```

3. **Push & Create PR**
   ```bash
   git push origin feature/your-feature
   ```
   - Title: Clear, concise description
   - Description: Explain what and why
   - Reference issues: Fixes #123
   - Link to related PRs if any

### PR Review Process

1. **Automated Checks**
   - CI/CD pipeline validation
   - Code style verification
   - Build on both toolchains

2. **Code Review**
   - At least one approval required
   - Address review feedback
   - Update tests if needed

3. **Merge**
   - Squash commits for clean history
   - Delete feature branch
   - Update relevant documentation

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

Example:
```
feat(codec): add H.265 encoder support

Implement hardware-accelerated H.265 encoding
for SS928V100 devices.

- Add encoder initialization
- Implement frame processing pipeline
- Add unit tests

Fixes #245
Closes #123
```

### Reporting Issues

Include in issue reports:
- **Description:** What's wrong?
- **Steps:** How to reproduce?
- **Expected:** What should happen?
- **Actual:** What actually happens?
- **Environment:** OS, toolchain, version
- **Logs:** Relevant error messages

---

## 📚 Additional Resources

### Official Documentation
- OpenHarmony: https://docs.openharmony.cn
- HiSilicon: Contact HiSilicon support
- Linux Kernel 6.6: https://kernel.org/doc

### Learning Materials
- Embedded Linux Guide: https://elinux.org
- Multimedia Development: See docs/zh-CN/
- Sample Code: platform/ss928v100_gcc/smp/

### Community & Support
- Gitee Issues: Report bugs and request features
- Discussions: Share knowledge with community
- Email: Submit detailed questions with examples

---

## 📞 Support & Contact

- **Issues:** https://gitee.com/HiSpark/pegasus/issues
- **Discussions:** Gitee community forums
- **Documentation:** See docs/ directory
- **Samples:** Check platform/*/smp/ directories

---

**Happy coding! 🎉**

Last updated: May 2026
