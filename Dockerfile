FROM toetje585/arch-fs25server:latest

USER root

# Pelican forces containers to run as uid 1000. Adapt the image so it can
# start and operate without root.

# Create a matching user/group and make nobody resolve to uid 1000 so the
# existing supervisord configs and scripts keep working.
RUN groupadd -g 1000 container 2>/dev/null || true && \
    useradd -u 1000 -g 1000 -d /home/container -s /bin/bash container 2>/dev/null || true && \
    usermod -u 1000 nobody 2>/dev/null || true && \
    groupmod -g 1000 users 2>/dev/null || true

# Redirect /config (binhex hard-coded path) to Pelican's /home/container.
RUN rm -rf /config && mkdir -p /home/container && ln -sf /home/container /config

# Keep the FS25 XML templates somewhere accessible before replacing /home/nobody.
RUN cp -a /home/nobody/.build/fs25 /usr/local/share/fs25-templates && \
    rm -rf /home/nobody && ln -s /config/home /home/nobody && \
    chown 1000:1000 /home && chmod 755 /home

# Replace the read-only /opt/fs25 with a symlink into /config (which itself
# points to Pelican's writable /home/container volume).
RUN rm -rf /opt/fs25 /config/opt/fs25 && \
    mkdir -p /config/opt/fs25 && \
    ln -s /config/opt/fs25 /opt/fs25 && \
    chown -R 1000:1000 /config /opt/fs25 && \
    chmod -R 755 /config

# Supervisord must not try to switch to another user when running as uid 1000.
# Also remove the top-level [supervisord] user=root directive and move the
# unix socket to /home/container (the only writable volume Pelican mounts).
RUN sed -i '/^user = nobody$/d' /etc/supervisor/conf.d/*.conf && \
    sed -i '/^user = root$/d' /etc/supervisord.conf && \
    sed -i 's|^file=/run/supervisor.sock|file=/home/container/.supervisor.sock|' /etc/supervisord.conf && \
    sed -i 's|unix:///run/supervisor.sock|unix:///home/container/.supervisor.sock|' /etc/supervisord.conf && \
    chown -R 1000:1000 /etc/supervisor /etc/supervisord.conf /var/log/supervisor && \
    chmod -R 755 /etc/supervisor /etc/supervisord.conf

# Install automation tools for headless setup via X/Wine, plus the Vulkan/D3D12
# stack. The dedicated server runs on the engine's null render device, but the
# vkd3d + lavapipe packages keep DXGI/GPU enumeration from hard-failing.
# libgcc/libstdc++ conflict with the base image gcc-libs files, hence --overwrite.
RUN pacman -Sy --noconfirm \
        --overwrite '/usr/lib/libgcc_s.so.1,/usr/lib/libstdc++.so*' \
        xdotool xorg-xwininfo xorriso \
        vkd3d lib32-vkd3d vulkan-swrast vulkan-icd-loader lib32-vulkan-icd-loader && \
    rm -rf /var/cache/pacman/pkg/*

# Add headless installer and activation helpers.
COPY install_fs25.sh /usr/local/bin/install_fs25.sh
COPY activate_fs25.sh /usr/local/bin/activate_fs25.sh
RUN chmod +x /usr/local/bin/install_fs25.sh /usr/local/bin/activate_fs25.sh

# Replace init.sh with a patched version that skips root-only commands.
COPY init.sh /usr/bin/init.sh
RUN chmod +x /usr/bin/init.sh

# Runtime helper scripts reference /home/nobody/.build/fs25 for templates. Because
# Pelican runs the container with a read-only root filesystem, point them to the
# writable /tmp/fs25-build copy created by init.sh at runtime.
RUN sed -i 's|/home/nobody/.build/fs25|/home/container/.fs25-build|g' /usr/local/bin/copy_server_config.sh

# Pelican converts boolean environment variables to 1/0, so accept "1" as true.
RUN sed -i 's|\[\[ \$AUTOSTART_SERVER = "true" \]\]|[[ $AUTOSTART_SERVER = "true" ]] \|\| [[ $AUTOSTART_SERVER = "1" ]]|g' /usr/local/bin/autostart_fs25.sh

# Make sure the runtime user can write supervisord.log and state files.
RUN touch /config/supervisord.log && chown -R 1000:1000 /config && chmod 666 /config/supervisord.log 2>/dev/null || true

USER 1000:1000
ENV HOME=/home/container USER=container
WORKDIR /home/container

CMD ["/bin/bash", "/usr/bin/init.sh"]
