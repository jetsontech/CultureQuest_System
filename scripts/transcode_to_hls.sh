#!/usr/bin/env bash
set -e
if [ "$#" -lt 2 ]; then
  echo "Usage: ./scripts/transcode_to_hls.sh input.mp4 output_dir"
  exit 1
fi
INPUT_FILE="$1"
OUTPUT_DIR="$2"
mkdir -p "$OUTPUT_DIR"
ffmpeg -y -i "$INPUT_FILE"   -c:v libx264   -preset veryfast   -c:a aac   -b:a 128k   -f hls   -hls_time 6   -hls_list_size 0   -hls_segment_filename "$OUTPUT_DIR/segment_%03d.ts"   "$OUTPUT_DIR/index.m3u8"
