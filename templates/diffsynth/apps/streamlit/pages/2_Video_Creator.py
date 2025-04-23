import logging
import sys
import os
import torch
import streamlit as st
import gc

# Suppress "missing ScriptRunContext" warnings
logging.getLogger("streamlit.runtime.scriptrunner").setLevel(logging.ERROR)

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../")))

from diffsynth import ModelManager, save_video, VideoData, download_models, CogVideoPipeline
from diffsynth.extensions.RIFE import RIFEInterpolater

# Verify model files
def verify_model_files(model_paths):
    """Verify that all model files exist and are non-empty."""
    for path in model_paths:
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            return False
    return True

# Initialize model manager and download required models
@st.cache_resource(show_spinner="Loading models...")
def load_model_manager():
    model_paths = [
        "models/CogVideo/CogVideoX-5b/text_encoder",
        "models/CogVideo/CogVideoX-5b/transformer",
        "models/CogVideo/CogVideoX-5b/vae/diffusion_pytorch_model.safetensors",
        "models/RIFE/flownet.pkl",
    ]
    
    if not verify_model_files(model_paths):
        with st.spinner("Downloading models..."):
            st.warning("Model files are missing or corrupted. Re-downloading models...")
            download_models()  # Ensure models are downloaded
            return None
    else:
        manager = ModelManager(torch_dtype=torch.bfloat16)
        manager.load_models(model_paths)
        return manager

# Use the cached model manager
model_manager = load_model_manager()

# Helper functions for video generation
# Ensure video file is closed before playback
def free_gpu_memory():
    """Free GPU memory to avoid CUDA out-of-memory errors."""
    gc.collect()
    torch.cuda.empty_cache()
    torch.cuda.ipc_collect()

def text_to_video(model_manager, prompt, seed, output_path, num_inference_steps):
    pipe = CogVideoPipeline.from_model_manager(model_manager)
    torch.manual_seed(seed)
    
    # Add progress bar
    progress_bar = st.progress(0)
    try:
        video = pipe(
            prompt=prompt,
            height=480, width=720,
            cfg_scale=7.0, num_inference_steps=num_inference_steps,
            progress_bar_st=progress_bar
        )
        save_video(video, output_path, fps=8, quality=5)
        del video  # Ensure the file is closed and accessible
    finally:
        free_gpu_memory()  # Free GPU memory
        progress_bar.empty()  # Clear the progress bar

def edit_video(model_manager, prompt, seed, input_path, output_path, num_inference_steps):
    pipe = CogVideoPipeline.from_model_manager(model_manager)
    input_video = VideoData(video_file=input_path)
    torch.manual_seed(seed)

    progress_bar = st.progress(0)

    try:
        video = pipe(
            prompt=prompt,
            height=480, width=720,
            cfg_scale=7.0, num_inference_steps=num_inference_steps,
            input_video=input_video, denoising_strength=0.7,
            progress_bar_st=progress_bar
        )
        save_video(video, output_path, fps=8, quality=5)
        del video  # Ensure the file is closed and accessible
    finally:
        free_gpu_memory()  # Free GPU memory

def interpolate_video(model_manager, input_path, output_path):
    rife = RIFEInterpolater.from_model_manager(model_manager)
    video = VideoData(video_file=input_path).raw_data()
    
    # Convert video frames to PIL Images if necessary
    from PIL import Image
    if isinstance(video, list):
        video = [Image.fromarray(frame) if not isinstance(frame, Image.Image) else frame for frame in video]

    # Ensure tensor sizes match
    try:
        video = rife.interpolate(video, num_iter=2)
    except RuntimeError as e:
        if "size of tensor" in str(e):
            # Resize tensors to match dimensions
            target_size = min(video[0].size[0], 32)  # Example: match to 32 or smaller
            video = [frame.resize((target_size, target_size), Image.BILINEAR) for frame in video]
            video = rife.interpolate(video, num_iter=2)
        else:
            raise e

    save_video(video, output_path, fps=32, quality=5)

# Streamlit UI
st.title("Video Creator")

with st.expander("Generate Video", expanded=True):
    prompt = st.text_area("Prompt", value="An astronaut riding a horse on Mars.")
    seed = st.number_input("Seed", min_value=0, max_value=10**9, step=1, value=0)
    num_inference_steps = st.slider("Inference steps", min_value=1, max_value=100, value=10, key="generate_steps")
    output_path = st.text_input("Output Path", value="output_video.mp4")
    if st.button("Generate"):
        text_to_video(model_manager, prompt, seed, output_path, num_inference_steps)
        st.success(f"Video generated at {output_path}")
        # Ensure video is playable by reloading it
        with open(output_path, "rb") as video_file:
            st.video(video_file.read())

with st.expander("Edit Video", expanded=False):
    prompt = st.text_area("Edit Prompt", value="A white robot riding a horse on Mars.")
    seed = st.number_input("Edit Seed", min_value=0, max_value=10**9, step=1, value=1)
    input_path = st.text_input("Input Video Path", value="output_video.mp4")
    output_path = st.text_input("Edited Output Path", value="edited_video.mp4")
    num_inference_steps = st.slider("Inference steps", min_value=1, max_value=100, value=10, key="edit_steps")
    if st.button("Edit"):
        edit_video(model_manager, prompt, seed, input_path, output_path, num_inference_steps)
        st.success(f"Video edited at {output_path}")
        st.video(output_path)

with st.expander("Interpolate Video", expanded=False):
    input_path = st.text_input("Interpolation Input Path", value="edited_video.mp4")
    output_path = st.text_input("Interpolated Output Path", value="interpolated_video.mp4")
    if st.button("Interpolate"):
        interpolate_video(model_manager, input_path, output_path)
        st.success(f"Video interpolated at {output_path}")
        st.video(output_path)
