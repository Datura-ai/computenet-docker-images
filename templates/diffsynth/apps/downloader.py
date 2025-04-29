import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))

# Define a persistent directory for models

models = ["RIFE", "StableDiffusionXL_Turbo", "CogVideoX-5B"]

print("Models:", models)

from diffsynth import download_models  # Ensure diffsynth is accessible
download_models(models, downloading_priority=["ModelScope"])