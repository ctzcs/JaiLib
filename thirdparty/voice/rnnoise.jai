// rnnoise（Xiph，BSD-3-Clause）动态加载绑定与降噪包装。
//
// rnnoise 固定 48kHz 单声道、480 样本（10ms）一帧，内部样本尺度为
// ±32768（short 尺度）；本包装在边界处做 ±1 缩放，调用方始终使用
// 归一化浮点样本。对应 MetaVoiceChat 的 RnnoiseVcInputFilter（可选）。

RNNOISE_FRAME_SAMPLES :: 480;
RNNOISE_SIGNAL_SCALE :: 32768.0;
RNNOISE_SIGNAL_SCALE_INV :: 1.0 / RNNOISE_SIGNAL_SCALE;

//@region 库加载

Rnnoise_Create_Proc :: #type (model: *void) -> *void #c_call;
Rnnoise_Destroy_Proc :: #type (state: *void) #c_call;
Rnnoise_Process_Frame_Proc :: #type (state: *void, out: *float32, input: *float32) -> float32 #c_call;

Rnnoise_Library :: struct {
    library: *void;

    create: Rnnoise_Create_Proc;
    destroy: Rnnoise_Destroy_Proc;
    process_frame: Rnnoise_Process_Frame_Proc;
}

// lib 由调用方持有（值语义）；成功填充字段，失败时 lib 保持零值。
rnnoise_load :: (lib: *Rnnoise_Library) -> bool {
    if lib == null {
        return false;
    }
    library, loaded := load_shared_library(shared_library_file("rnnoise"));
    if !loaded {
        #if OS == .LINUX {
            library, loaded = load_shared_library("librnnoise.so.0"); // 发行包带版本后缀
        }
        if !loaded {
            return false;
        }
    }

    lib.library = library;

    lib.create = cast(Rnnoise_Create_Proc) (shared_symbol_ptr(library, "rnnoise_create"));
    lib.destroy = cast(Rnnoise_Destroy_Proc) (shared_symbol_ptr(library, "rnnoise_destroy"));
    lib.process_frame = cast(Rnnoise_Process_Frame_Proc) (shared_symbol_ptr(library, "rnnoise_process_frame"));

    if lib.create == null || lib.destroy == null || lib.process_frame == null {
        rnnoise_dispose(lib);
        return false;
    }
    return true;
}

rnnoise_dispose :: (lib: *Rnnoise_Library) {
    if lib == null {
        return;
    }
    unload_shared_library(lib.library);
    lib.* = .{};
}

//@endregion

//@region 降噪器

Rnnoise_Denoiser :: struct {
    lib: *Rnnoise_Library;
    handle: *void;
    scaled: [RNNOISE_FRAME_SAMPLES] float32; // 缩放中间缓冲，降噪器所有
}

// 使用 rnnoise 内置默认模型（官方发布的模型已编入库内）。
rnnoise_denoiser_create :: (lib: *Rnnoise_Library) -> Rnnoise_Denoiser, bool {
    denoiser: Rnnoise_Denoiser;
    ok: bool;

    if lib == null {
        return .{}, false;
    }
    handle := lib.create(null);
    if handle == null {
        return .{}, false;
    }
    return .{ lib = lib, handle = handle }, true;
}

// 就地降噪一帧（480 样本、±1 浮点）；返回值为语音概率 [0,1]。
// 帧长不符返回 -1 且不改写输入。
rnnoise_denoise :: (denoiser: *Rnnoise_Denoiser, frame: [] float32) -> float32 {
    if denoiser == null || denoiser.handle == null || (frame).count != RNNOISE_FRAME_SAMPLES {
        return -1;
    }
    scaled := view(denoiser.scaled, 0);
    for sample, i: frame {
        scaled[i] = sample * RNNOISE_SIGNAL_SCALE;
    }
    probability := denoiser.lib.process_frame(denoiser.handle, *scaled[0], *scaled[0]);
    {
        i := 0;
        while i < (frame).count {
            defer i += 1;
            frame[i] = scaled[i] * RNNOISE_SIGNAL_SCALE_INV;
        }
    }
    return probability;
}

rnnoise_denoiser_destroy :: (denoiser: *Rnnoise_Denoiser) {
    if denoiser == null {
        return;
    }
    if denoiser.handle != null {
        denoiser.lib.destroy(denoiser.handle);
    }
    denoiser.* = .{};
}

//@endregion
