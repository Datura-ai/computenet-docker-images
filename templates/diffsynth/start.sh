#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

python apps/downloader.py & > downloads.txt
streamlit run apps/streamlit/DiffSynth_Studio.py

