{
  lib,
  stdenv,
  symlinkJoin,
  writeShellApplication,
  coreutils,
  libnotify,
  pkg-config,
  slurp,
  wayland,
  wayland-protocols,
  wayland-scanner,
  wf-recorder,
  wlr-protocols,
}:

let
  regionBorder = stdenv.mkDerivation {
    pname = "nyx-record-border";
    version = "1.0";

    dontUnpack = true;

    nativeBuildInputs = [
      pkg-config
      wayland-scanner
    ];

    buildInputs = [
      wayland
    ];

    buildPhase = ''
      runHook preBuild

      wayland-scanner client-header \
        ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml \
        wlr-layer-shell-unstable-v1-client-protocol.h
      wayland-scanner private-code \
        ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml \
        wlr-layer-shell-unstable-v1-protocol.c
      wayland-scanner client-header \
        ${wayland-protocols}/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml \
        xdg-output-unstable-v1-client-protocol.h
      wayland-scanner private-code \
        ${wayland-protocols}/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml \
        xdg-output-unstable-v1-protocol.c
      wayland-scanner client-header \
        ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
        xdg-shell-client-protocol.h
      wayland-scanner private-code \
        ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
        xdg-shell-protocol.c

      cat > nyx-record-border.c <<'EOF'
      #define _GNU_SOURCE
      #include <fcntl.h>
      #include <stdbool.h>
      #include <stdint.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/mman.h>
      #include <unistd.h>
      #include <wayland-client.h>

      #include "wlr-layer-shell-unstable-v1-client-protocol.h"
      #include "xdg-output-unstable-v1-client-protocol.h"

      struct app;

      struct output {
        struct wl_list link;
        struct app *app;
        struct wl_output *wl_output;
        struct zxdg_output_v1 *xdg_output;
        struct wl_surface *surface;
        struct zwlr_layer_surface_v1 *layer_surface;
        struct wl_buffer *buffer;
        void *data;
        size_t data_size;
        int32_t x;
        int32_t y;
        int32_t width;
        int32_t height;
        int32_t scale;
        bool configured;
      };

      struct app {
        struct wl_display *display;
        struct wl_registry *registry;
        struct wl_compositor *compositor;
        struct wl_shm *shm;
        struct zwlr_layer_shell_v1 *layer_shell;
        struct zxdg_output_manager_v1 *xdg_output_manager;
        struct wl_list outputs;
        int32_t region_x;
        int32_t region_y;
        int32_t region_width;
        int32_t region_height;
        uint32_t color;
        int32_t border_width;
        bool running;
      };

      static uint32_t premultiply(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
        r = (uint8_t)((uint16_t)r * a / 255);
        g = (uint8_t)((uint16_t)g * a / 255);
        b = (uint8_t)((uint16_t)b * a / 255);
        return ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
      }

      static uint32_t parse_color(const char *input) {
        const char *text = input != NULL && input[0] == '#' ? input + 1 : input;
        if (text == NULL) {
          return premultiply(235, 111, 146, 255);
        }

        size_t len = strlen(text);
        if (len != 6 && len != 8) {
          return premultiply(235, 111, 146, 255);
        }

        char *end = NULL;
        unsigned long value = strtoul(text, &end, 16);
        if (end == NULL || *end != '\0') {
          return premultiply(235, 111, 146, 255);
        }

        if (len == 6) {
          return premultiply((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff, 255);
        }

        return premultiply((value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff);
      }

      static bool parse_region(const char *text, struct app *app) {
        return sscanf(text, "%d,%d %dx%d", &app->region_x, &app->region_y, &app->region_width, &app->region_height) == 4
          && app->region_width > 0
          && app->region_height > 0;
      }

      static bool pixel_is_border(struct app *app, int32_t x, int32_t y) {
        int32_t right = app->region_x + app->region_width;
        int32_t bottom = app->region_y + app->region_height;
        int32_t border = app->border_width < 1 ? 1 : app->border_width;

        if (x < app->region_x || x >= right || y < app->region_y || y >= bottom) {
          return false;
        }

        return x - app->region_x < border
          || right - 1 - x < border
          || y - app->region_y < border
          || bottom - 1 - y < border;
      }

      static void destroy_buffer(struct output *output) {
        if (output->buffer != NULL) {
          wl_buffer_destroy(output->buffer);
          output->buffer = NULL;
        }
        if (output->data != NULL) {
          munmap(output->data, output->data_size);
          output->data = NULL;
          output->data_size = 0;
        }
      }

      static bool create_buffer(struct output *output, uint32_t width, uint32_t height) {
        struct app *app = output->app;
        destroy_buffer(output);

        if (width == 0 || height == 0) {
          return false;
        }

        int stride = (int)width * 4;
        size_t size = (size_t)stride * height;
        int fd = memfd_create("nyx-record-border", MFD_CLOEXEC);
        if (fd < 0) {
          perror("memfd_create");
          return false;
        }
        if (ftruncate(fd, (off_t)size) < 0) {
          perror("ftruncate");
          close(fd);
          return false;
        }

        void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) {
          perror("mmap");
          close(fd);
          return false;
        }

        uint32_t *pixels = data;
        memset(pixels, 0, size);

        for (uint32_t y = 0; y < height; y++) {
          int32_t global_y = output->y + (int32_t)y;
          for (uint32_t x = 0; x < width; x++) {
            int32_t global_x = output->x + (int32_t)x;
            if (pixel_is_border(app, global_x, global_y)) {
              pixels[(size_t)y * width + x] = app->color;
            }
          }
        }

        struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, (int)size);
        output->buffer = wl_shm_pool_create_buffer(pool, 0, (int)width, (int)height, stride, WL_SHM_FORMAT_ARGB8888);
        wl_shm_pool_destroy(pool);
        close(fd);

        output->data = data;
        output->data_size = size;
        return output->buffer != NULL;
      }

      static void layer_configure(
          void *data,
          struct zwlr_layer_surface_v1 *layer_surface,
          uint32_t serial,
          uint32_t width,
          uint32_t height) {
        struct output *output = data;
        zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
        output->configured = true;

        if (output->width == 0) {
          output->width = (int32_t)width;
        }
        if (output->height == 0) {
          output->height = (int32_t)height;
        }

        if (!create_buffer(output, width, height)) {
          output->app->running = false;
          return;
        }

        wl_surface_attach(output->surface, output->buffer, 0, 0);
        wl_surface_damage_buffer(output->surface, 0, 0, (int32_t)width, (int32_t)height);
        wl_surface_commit(output->surface);
      }

      static void layer_closed(void *data, struct zwlr_layer_surface_v1 *layer_surface) {
        (void)layer_surface;
        struct output *output = data;
        output->app->running = false;
      }

      static const struct zwlr_layer_surface_v1_listener layer_listener = {
        .configure = layer_configure,
        .closed = layer_closed,
      };

      static void output_geometry(
          void *data,
          struct wl_output *wl_output,
          int32_t x,
          int32_t y,
          int32_t physical_width,
          int32_t physical_height,
          int32_t subpixel,
          const char *make,
          const char *model,
          int32_t transform) {
        struct output *output = data;
        (void)wl_output;
        (void)physical_width;
        (void)physical_height;
        (void)subpixel;
        (void)make;
        (void)model;
        (void)transform;
        output->x = x;
        output->y = y;
      }

      static void output_mode(
          void *data,
          struct wl_output *wl_output,
          uint32_t flags,
          int32_t width,
          int32_t height,
          int32_t refresh) {
        struct output *output = data;
        (void)wl_output;
        (void)refresh;
        if ((flags & WL_OUTPUT_MODE_CURRENT) != 0) {
          output->width = width;
          output->height = height;
        }
      }

      static void output_done(void *data, struct wl_output *wl_output) {
        (void)data;
        (void)wl_output;
      }

      static void output_scale(void *data, struct wl_output *wl_output, int32_t factor) {
        struct output *output = data;
        (void)wl_output;
        output->scale = factor;
      }

      static const struct wl_output_listener output_listener = {
        .geometry = output_geometry,
        .mode = output_mode,
        .done = output_done,
        .scale = output_scale,
      };

      static void xdg_output_logical_position(void *data, struct zxdg_output_v1 *xdg_output, int32_t x, int32_t y) {
        struct output *output = data;
        (void)xdg_output;
        output->x = x;
        output->y = y;
      }

      static void xdg_output_logical_size(void *data, struct zxdg_output_v1 *xdg_output, int32_t width, int32_t height) {
        struct output *output = data;
        (void)xdg_output;
        output->width = width;
        output->height = height;
      }

      static void xdg_output_done(void *data, struct zxdg_output_v1 *xdg_output) {
        (void)data;
        (void)xdg_output;
      }

      static void xdg_output_name(void *data, struct zxdg_output_v1 *xdg_output, const char *name) {
        (void)data;
        (void)xdg_output;
        (void)name;
      }

      static void xdg_output_description(void *data, struct zxdg_output_v1 *xdg_output, const char *description) {
        (void)data;
        (void)xdg_output;
        (void)description;
      }

      static const struct zxdg_output_v1_listener xdg_output_listener = {
        .logical_position = xdg_output_logical_position,
        .logical_size = xdg_output_logical_size,
        .done = xdg_output_done,
        .name = xdg_output_name,
        .description = xdg_output_description,
      };

      static void registry_global(
          void *data,
          struct wl_registry *registry,
          uint32_t name,
          const char *interface,
          uint32_t version) {
        struct app *app = data;

        if (strcmp(interface, wl_compositor_interface.name) == 0) {
          app->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
        } else if (strcmp(interface, wl_shm_interface.name) == 0) {
          app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
        } else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
          app->layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, 1);
        } else if (strcmp(interface, zxdg_output_manager_v1_interface.name) == 0) {
          app->xdg_output_manager = wl_registry_bind(registry, name, &zxdg_output_manager_v1_interface, version < 3 ? version : 3);
        } else if (strcmp(interface, wl_output_interface.name) == 0) {
          struct output *output = calloc(1, sizeof(*output));
          if (output == NULL) {
            return;
          }
          output->app = app;
          output->scale = 1;
          output->wl_output = wl_registry_bind(registry, name, &wl_output_interface, version < 3 ? version : 3);
          wl_output_add_listener(output->wl_output, &output_listener, output);
          wl_list_insert(app->outputs.prev, &output->link);
        }
      }

      static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
        (void)data;
        (void)registry;
        (void)name;
      }

      static const struct wl_registry_listener registry_listener = {
        .global = registry_global,
        .global_remove = registry_remove,
      };

      static bool create_surface(struct output *output) {
        struct app *app = output->app;
        output->surface = wl_compositor_create_surface(app->compositor);
        if (output->surface == NULL) {
          return false;
        }

        struct wl_region *empty_input = wl_compositor_create_region(app->compositor);
        wl_surface_set_input_region(output->surface, empty_input);
        wl_region_destroy(empty_input);

        output->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
            app->layer_shell,
            output->surface,
            output->wl_output,
            ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "nyx-record-border");
        if (output->layer_surface == NULL) {
          return false;
        }

        zwlr_layer_surface_v1_add_listener(output->layer_surface, &layer_listener, output);
        zwlr_layer_surface_v1_set_anchor(
            output->layer_surface,
            ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
        zwlr_layer_surface_v1_set_exclusive_zone(output->layer_surface, -1);
        zwlr_layer_surface_v1_set_keyboard_interactivity(output->layer_surface, 0);
        wl_surface_commit(output->surface);
        return true;
      }

      static void destroy_output(struct output *output) {
        destroy_buffer(output);
        if (output->layer_surface != NULL) {
          zwlr_layer_surface_v1_destroy(output->layer_surface);
        }
        if (output->surface != NULL) {
          wl_surface_destroy(output->surface);
        }
        if (output->xdg_output != NULL) {
          zxdg_output_v1_destroy(output->xdg_output);
        }
        if (output->wl_output != NULL) {
          wl_output_destroy(output->wl_output);
        }
        wl_list_remove(&output->link);
        free(output);
      }

      int main(int argc, char **argv) {
        if (argc < 2 || !parse_region(argv[1], &(struct app){0})) {
          fprintf(stderr, "usage: nyx-record-border 'x,y WIDTHxHEIGHT' [rrggbbaa] [border-width]\n");
          return EXIT_FAILURE;
        }

        struct app app = {
          .color = parse_color(argc > 2 ? argv[2] : "eb6f92ff"),
          .border_width = argc > 3 ? atoi(argv[3]) : 4,
          .running = true,
        };
        wl_list_init(&app.outputs);

        if (!parse_region(argv[1], &app)) {
          fprintf(stderr, "invalid region: %s\n", argv[1]);
          return EXIT_FAILURE;
        }

        app.display = wl_display_connect(NULL);
        if (app.display == NULL) {
          fprintf(stderr, "failed to connect to Wayland display\n");
          return EXIT_FAILURE;
        }

        app.registry = wl_display_get_registry(app.display);
        wl_registry_add_listener(app.registry, &registry_listener, &app);
        wl_display_roundtrip(app.display);

        if (app.compositor == NULL || app.shm == NULL || app.layer_shell == NULL) {
          fprintf(stderr, "missing required Wayland protocol support\n");
          return EXIT_FAILURE;
        }

        if (app.xdg_output_manager != NULL) {
          struct output *output;
          wl_list_for_each(output, &app.outputs, link) {
            output->xdg_output = zxdg_output_manager_v1_get_xdg_output(app.xdg_output_manager, output->wl_output);
            zxdg_output_v1_add_listener(output->xdg_output, &xdg_output_listener, output);
          }
          wl_display_roundtrip(app.display);
        } else {
          struct output *output;
          wl_list_for_each(output, &app.outputs, link) {
            output->width /= output->scale;
            output->height /= output->scale;
          }
        }

        struct output *output;
        wl_list_for_each(output, &app.outputs, link) {
          if (!create_surface(output)) {
            return EXIT_FAILURE;
          }
        }

        while (app.running && wl_display_dispatch(app.display) != -1) {
        }

        struct output *tmp;
        wl_list_for_each_safe(output, tmp, &app.outputs, link) {
          destroy_output(output);
        }
        if (app.xdg_output_manager != NULL) {
          zxdg_output_manager_v1_destroy(app.xdg_output_manager);
        }
        zwlr_layer_shell_v1_destroy(app.layer_shell);
        wl_compositor_destroy(app.compositor);
        wl_shm_destroy(app.shm);
        wl_registry_destroy(app.registry);
        wl_display_disconnect(app.display);
        return EXIT_SUCCESS;
      }
      EOF

      $CC -Wall -Wextra -O2 \
        nyx-record-border.c \
        wlr-layer-shell-unstable-v1-protocol.c \
        xdg-output-unstable-v1-protocol.c \
        xdg-shell-protocol.c \
        -o nyx-record-border \
        $(pkg-config --cflags --libs wayland-client)

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 nyx-record-border "$out/bin/nyx-record-border"
      runHook postInstall
    '';
  };

  recordRegion = writeShellApplication {
    name = "nyx-record-region";

    runtimeInputs = [
      coreutils
      libnotify
      regionBorder
      slurp
      wf-recorder
    ];

    text = ''
      state_dir="''${XDG_RUNTIME_DIR:-/tmp}/nyx-recorder"
      pid_file="$state_dir/wf-recorder.pid"
      overlay_pid_file="$state_dir/border.pid"
      output_file="$state_dir/output"

      mkdir -p "$state_dir"

      if [ -s "$pid_file" ]; then
        old_pid="$(cat "$pid_file")"
        if kill -0 "$old_pid" 2>/dev/null; then
          notify-send -t 5000 "Recording already running" "Press Super+Shift+Print to stop it."
          exit 1
        fi
        rm -f "$pid_file" "$overlay_pid_file" "$output_file"
      fi

      recording_dir="''${XDG_VIDEOS_DIR:-$HOME/Videos}/Recordings"
      mkdir -p "$recording_dir"

      region="$(slurp -b "00000033" -c "ffffffff" -s "eb6f9240" -w 2)" || exit 0
      [ -n "$region" ] || exit 0

      file="$recording_dir/Recording-$(date +%Y-%m-%d-%H-%M-%S).mp4"
      border_color="''${NYX_RECORD_BORDER_COLOR:-eb6f92ff}"
      border_width="''${NYX_RECORD_BORDER_WIDTH:-4}"

      nyx-record-border "$region" "$border_color" "$border_width" &
      overlay_pid="$!"
      printf '%s\n' "$overlay_pid" > "$overlay_pid_file"

      # shellcheck disable=SC2329
      cleanup() {
        if kill -0 "$overlay_pid" 2>/dev/null; then
          kill "$overlay_pid" 2>/dev/null || true
          wait "$overlay_pid" 2>/dev/null || true
        fi
        rm -f "$pid_file" "$overlay_pid_file" "$output_file"
      }
      trap cleanup EXIT

      notify-send -t 3500 "Recording started" "$region"
      wf-recorder -g "$region" -f "$file" -c libx264 -p preset=veryfast -p crf=18 &
      recorder_pid="$!"
      printf '%s\n' "$recorder_pid" > "$pid_file"
      printf '%s\n' "$file" > "$output_file"

      status=0
      wait "$recorder_pid" || status="$?"

      if [ "$status" -eq 0 ]; then
        notify-send -t 6000 "Recording saved" "$(basename "$file")"
      else
        notify-send -t 6000 "Recording stopped" "$(basename "$file")"
      fi

      exit "$status"
    '';
  };

  recordStop = writeShellApplication {
    name = "nyx-record-stop";

    runtimeInputs = [
      coreutils
      libnotify
    ];

    text = ''
      state_dir="''${XDG_RUNTIME_DIR:-/tmp}/nyx-recorder"
      pid_file="$state_dir/wf-recorder.pid"
      overlay_pid_file="$state_dir/border.pid"

      stopped=false

      if [ -s "$pid_file" ]; then
        pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
          kill -INT "$pid" 2>/dev/null || true
          stopped=true
        fi
      fi

      if [ -s "$overlay_pid_file" ]; then
        overlay_pid="$(cat "$overlay_pid_file")"
        kill "$overlay_pid" 2>/dev/null || true
      fi

      if [ "$stopped" = true ]; then
        notify-send -t 3500 "Stopping recording" "Saving video..."
      else
        rm -f "$pid_file" "$overlay_pid_file"
        notify-send -t 4000 "No recording running"
      fi
    '';
  };
in
symlinkJoin {
  name = "nyx-recorder";
  paths = [
    recordRegion
    recordStop
  ];

  meta = {
    description = "Region recording helpers for Nyx";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ dx ];
    platforms = lib.platforms.linux;
  };
}
