# Stage 1: build
FROM gradle:8.10-jdk21 AS builder

WORKDIR /workspace

# Copy build descriptor files first for layer caching
COPY build.gradle settings.gradle ./

# Download dependencies (will be cached if build files don't change)
RUN gradle dependencies --no-daemon || true

# Copy source
COPY src ./src

# Build the fat jar
RUN gradle bootJar --no-daemon

# Stage 2: runtime
FROM eclipse-temurin:21-jre

WORKDIR /app

COPY --from=builder /workspace/build/libs/*.jar app.jar

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
