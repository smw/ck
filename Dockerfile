# Multi-stage Dockerfile with layer caching optimization
# Similar to Kubernetes staged deployments

###################
# Dependencies Stage (cached separately)
###################
FROM rust:1.75 AS dependencies

WORKDIR /app

# Copy dependency manifests first (layer caching)
COPY Cargo.toml ./
# Copy Cargo.lock if it exists (optional for robustness)
COPY Cargo.loc[k] ./
COPY */Cargo.toml ./*/

# Create dummy source files to build dependencies
RUN find . -name "Cargo.toml" -exec dirname {} \; | \
    while read dir; do \
        mkdir -p "$dir/src" && \
        echo "fn main() {}" > "$dir/src/main.rs" && \
        echo "pub fn add(left: usize, right: usize) -> usize { left + right }" > "$dir/src/lib.rs"; \
    done

# Install build dependencies for vendored OpenSSL
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        && rm -rf /var/lib/apt/lists/*

# Build dependencies (this layer gets cached)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release

# Clean up dummy files but keep target/release/deps
RUN find target/release -name "ck*" -type f -delete 2>/dev/null || true
RUN find target/release -name "*ck*" -type d -exec rm -rf {} + 2>/dev/null || true
RUN find . -name "*.rs" -path "*/src/*" -delete

###################  
# Build Stage (only rebuilds when source changes)
###################
FROM rust:1.75 AS builder

WORKDIR /app

# Install build dependencies for vendored OpenSSL
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        && rm -rf /var/lib/apt/lists/*

# Copy cached dependencies from previous stage
COPY --from=dependencies /app/target target/
COPY --from=dependencies /usr/local/cargo /usr/local/cargo

# Copy dependency manifests
COPY Cargo.toml ./
COPY Cargo.loc[k] ./
COPY */Cargo.toml ./*/

# Copy actual source code (separate layer)
COPY . .

# Build the actual application
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release --bin ck

# Copy binary to a known location
RUN cp target/release/ck /usr/local/bin/ck

###################
# Runtime Stage (minimal final image)
###################
FROM debian:bookworm-slim AS runtime

# Install minimal runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r ck && useradd -r -g ck ck

# Copy binary from build stage
COPY --from=builder /usr/local/bin/ck /usr/local/bin/ck
RUN chmod +x /usr/local/bin/ck

# Switch to non-root user
USER ck

# Set working directory
WORKDIR /app

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ck --version || exit 1

# Default command
ENTRYPOINT ["ck"]
CMD ["--help"]