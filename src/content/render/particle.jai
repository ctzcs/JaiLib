// particle.jai
// Port of Ascension/src/content/particle.odin

#import "Basic";
#import "tween/math_util";
#import "bindings/raylib";
#import "content/core/const";

Particle_Render_Kind :: enum u8 {
    Rect;
    Texture;
}

Particle :: struct {
    pos:               Vector2;
    vel:               Vector2;
    life:              float32;
    max_life:          float32;
    size:              Vector2;
    color:             Color;
    render_kind:       Particle_Render_Kind;
    texture:           Texture;
    source:            Rectangle;
    gravity:           float32;
    drag:              float32;
    angle:             float32;
    rotate_speed:      float32;
    align_to_velocity: bool;
    active:            bool;
}

Particle_Spawn :: struct {
    pos:               Vector2;
    vel:               Vector2;
    life:              float32;
    size:              Vector2;
    color:             Color;
    render_kind:       Particle_Render_Kind;
    texture:           Texture;
    source:            Rectangle;
    gravity:           float32;
    drag:              float32;
    angle:             float32;
    rotate_speed:      float32;
    align_to_velocity: bool;
}

Particle_System :: struct {
    storage:         [MAX_PARTICLES] Particle;
    next_emit_index: int;
}

particle_system_init :: (system: *Particle_System) {
    system.next_emit_index = 0;
    particle_system_clear(system);
}

particle_system_clear :: (system: *Particle_System) {
    system.next_emit_index = 0;
    i := 0;
    while i < MAX_PARTICLES {
        system.storage[i] = Particle.{};
        i += 1;
    }
}

particle_system_active_count :: (system: *Particle_System) -> int {
    count := 0;
    i := 0;
    while i < MAX_PARTICLES {
        if system.storage[i].active {
            count += 1;
        }
        i += 1;
    }
    return count;
}

particle_system_emit :: (system: *Particle_System, spawn: Particle_Spawn) -> bool {
    start := system.next_emit_index;
    step := 0;
    while step < MAX_PARTICLES {
        i := (start + step) % MAX_PARTICLES;
        particle := *system.storage[i];
        if particle.active {
            step += 1;
            continue;
        }

        <<particle = Particle.{
            pos = spawn.pos,
            vel = spawn.vel,
            life = spawn.life,
            max_life = spawn.life,
            size = spawn.size,
            color = spawn.color,
            render_kind = spawn.render_kind,
            texture = spawn.texture,
            source = spawn.source,
            gravity = spawn.gravity,
            drag = spawn.drag,
            angle = spawn.angle,
            rotate_speed = spawn.rotate_speed,
            align_to_velocity = spawn.align_to_velocity,
            active = true,
        };
        system.next_emit_index = (i + 1) % MAX_PARTICLES;
        return true;
    }

    return false;
}

particle_system_update :: (system: *Particle_System, dt: float32) {
    i := 0;
    while i < MAX_PARTICLES {
        particle := *system.storage[i];
        if !particle.active {
            i += 1;
            continue;
        }

        particle.life -= dt;
        if particle.life <= 0 {
            particle.active = false;
            i += 1;
            continue;
        }

        particle.vel.y += particle.gravity * dt;
        particle.vel.x *= particle.drag;
        particle.vel.y *= particle.drag;
        particle.pos.x += particle.vel.x * dt;
        particle.pos.y += particle.vel.y * dt;

        if particle.align_to_velocity {
            if particle.vel.x != 0 || particle.vel.y != 0 {
                particle.angle = math_atan2(particle.vel.y, particle.vel.x) * RAD_TO_DEG;
            }
        } else {
            particle.angle += particle.rotate_speed * dt;
        }
        i += 1;
    }
}

particle_system_draw :: (system: *Particle_System) {
    i := 0;
    while i < MAX_PARTICLES {
        particle := system.storage[i];
        if !particle.active {
            i += 1;
            continue;
        }

        life_ratio := clamp(particle.life / particle.max_life, 0.0, 1.0);
        color := particle.color;
        color.a = cast(u8) (cast(float32) color.a * life_ratio);

        dest := Rectangle.{ x = particle.pos.x, y = particle.pos.y, width = particle.size.x, height = particle.size.y };
        origin := Vector2.{ x = particle.size.x * 0.5, y = particle.size.y * 0.5 };

        if particle.render_kind == .Texture {
            src := particle.source;
            if src.width == 0 || src.height == 0 {
                src = Rectangle.{ x = 0, y = 0, width = cast(float32) particle.texture.width, height = cast(float32) particle.texture.height };
            }
            DrawTexturePro(particle.texture, src, dest, origin, particle.angle, color);
        } else if particle.render_kind == .Rect {
            DrawRectanglePro(dest, origin, particle.angle, color);
        }
        i += 1;
    }
}
