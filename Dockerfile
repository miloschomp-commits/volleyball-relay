# The relay server, ready for a free host like Render (ONLINE.md): a small Linux with
# Godot (no window) running relay.gd. The host sets PORT; relay.gd listens on it.
FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
	&& rm -rf /var/lib/apt/lists/*

RUN wget -q https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip -O /tmp/godot.zip \
	&& unzip /tmp/godot.zip -d /tmp \
	&& mv /tmp/Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot \
	&& chmod +x /usr/local/bin/godot \
	&& rm /tmp/godot.zip

WORKDIR /app
COPY relay.gd .
CMD ["godot", "--headless", "--script", "relay.gd"]
