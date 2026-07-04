#!/usr/bin/env bash

# 依赖检查
for cmd in ffmpeg ffprobe bc; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误: 未找到 $cmd，请先安装。"
        exit 1
    fi
done

# 检测 NVIDIA GPU
hwaccel_available=0
if command -v nvidia-smi &> /dev/null; then
    echo "检测到 NVIDIA GPU，将根据编码类型使用硬件加速。"
    hwaccel_available=1
else
    echo "未检测到 NVIDIA GPU，使用 CPU 解码。"
fi

echo "----------------------------------------"
read -p "请输入输出目录（默认当前目录）: " OUTPUT_DIR || true
OUTPUT_DIR="${OUTPUT_DIR:-.}"
mkdir -p "$OUTPUT_DIR"
echo "输出目录: $OUTPUT_DIR"
echo "----------------------------------------"

# 判断输出目录是否为当前目录
CURRENT_DIR="$(pwd -P)"
OUTPUT_ABS="$(cd "$OUTPUT_DIR" && pwd -P)" 2>/dev/null || OUTPUT_ABS="$(realpath "$OUTPUT_DIR" 2>/dev/null || echo "$OUTPUT_DIR")"
if [ "$OUTPUT_ABS" = "$CURRENT_DIR" ]; then
    IS_CURRENT_DIR=1
else
    IS_CURRENT_DIR=0
fi

# 视频编码选择
echo "请选择视频编码格式（每个选项后为输出文件后缀名）:"
video_options=(
    "ProRes 422 HQ (高质量剪辑用) -> .mov"
    "H.264 无损 NVENC (仅NVIDIA GPU) -> .mp4"
    "H.264 高质量 NVENC (适合分发) -> .mp4"
    "H.265 高质量 NVENC (需GPU支持) -> .mp4"
    "DNxHD (Avid 剪辑用) -> .mov"
)
for i in "${!video_options[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${video_options[$i]}"
done
read -p "请输入编号 [1-5] (默认1): " v_choice || true
v_choice="${v_choice:-1}"

case "$v_choice" in
    1)
        container="mov"
        video_codec="prores_ks -profile:v 4"
        pix_fmt="yuva444p10le"
        v_desc="ProRes 422 HQ"
        is_nvenc=0
        ;;
    2)
        container="mp4"
        video_codec="h264_nvenc -preset p7 -tune lossless"
        v_desc="H.264 无损 (NVENC)"
        is_nvenc=1
        ;;
    3)
        container="mp4"
        video_codec="h264_nvenc -preset p7 -rc vbr -cq 18 -b:v 0"
        v_desc="H.264 高质量 (NVENC)"
        is_nvenc=1
        ;;
    4)
        container="mp4"
        video_codec="hevc_nvenc -preset p7 -rc vbr -cq 18 -b:v 0"
        v_desc="H.265 高质量 (NVENC)"
        is_nvenc=1
        ;;
    5)
        container="mov"
        video_codec="dnxhd -profile:v dnxhd_1080p"
        pix_fmt="yuv422p"
        v_desc="DNxHD"
        is_nvenc=0
        ;;
    *)
        echo "无效选择，退出。"
        exit 1
        ;;
esac
echo "已选视频编码: $v_desc (容器: .$container)"
echo "----------------------------------------"

# 音频处理选择（PCM 放第一位）
echo "请选择音频处理方式（常见容器后缀参考）:"
audio_options=(
    "PCM 无损 (pcm_s16le) -> 常用于 .mov / .wav"
    "直接复制源音轨 (不重新编码) -> 保持原始音频"
    "AAC 高质量 (aac -b:a 192k) -> 常用于 .mp4 / .m4a"
    "MP3 高质量 (libmp3lame -b:a 320k) -> 常用于 .mp3 / .mp4"
    "AC-3 环绕声 (ac3 -b:a 448k) -> 常用于 .mp4 / .mkv"
)
for i in "${!audio_options[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${audio_options[$i]}"
done
read -p "请输入编号 [1-5] (默认1): " a_choice || true
a_choice="${a_choice:-1}"

case "$a_choice" in
    1)
        audio_codec="pcm_s16le"
        a_desc="PCM 无损"
        ;;
    2)
        audio_codec="copy"
        a_desc="复制源音轨"
        ;;
    3)
        audio_codec="aac -b:a 192k"
        a_desc="AAC 192k"
        ;;
    4)
        audio_codec="libmp3lame -b:a 320k"
        a_desc="MP3 320k"
        ;;
    5)
        audio_codec="ac3 -b:a 448k"
        a_desc="AC-3 448k"
        ;;
    *)
        echo "无效选择，退出。"
        exit 1
        ;;
esac
echo "已选音频处理: $a_desc"
echo "----------------------------------------"

# 并行任务数
read -p "请输入并行任务数（同时转换多个文件，默认1，串行）: " PARALLEL_JOBS || true
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_JOBS" -lt 1 ]; then
    PARALLEL_JOBS=1
fi
echo "并行任务数: $PARALLEL_JOBS"
echo "----------------------------------------"

# 支持的输入后缀
extensions=(
    "mov" "mp4" "mkv" "avi" "m4v"
    "3gp" "flv" "wmv" "webm" "mpeg" "mpg"
)
echo "当前脚本支持处理的输入文件后缀名（不区分大小写）:"
for e in "${extensions[@]}"; do
    printf "  .%s " "$e"
done
echo -e "\n----------------------------------------"

# 收集匹配的文件
files=()
for file in *; do
    [ -f "$file" ] || continue
    ext="${file##*.}"
    ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    for e in "${extensions[@]}"; do
        if [ "$ext_lower" = "$e" ]; then
            files+=("$file")
            break
        fi
    done
done

if [ ${#files[@]} -eq 0 ]; then
    echo "未找到任何支持的视频文件。"
    exit 0
fi

echo "找到以下文件将被处理："
for i in "${!files[@]}"; do
    echo "  $((i+1)). ${files[$i]}"
done
echo "----------------------------------------"

# 获取总时长（用于串行进度）
declare -A file_duration
total_duration=0
for file in "${files[@]}"; do
    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    if [[ -z "$dur" || "$dur" = "N/A" ]]; then
        echo "警告: 无法获取 $file 的时长，跳过该文件。"
        continue
    fi
    file_duration["$file"]="$dur"
    total_duration=$(echo "$total_duration + $dur" | bc)
done

if [ -z "$total_duration" ] || [ "$total_duration" = "0" ]; then
    echo "错误: 无法计算总时长，请检查文件。"
    exit 1
fi

echo "共找到 ${#files[@]} 个文件，总时长: $(date -u -d @${total_duration%.*} +%H:%M:%S)"
echo "----------------------------------------"

# 全局操作选择（只问一次）
if [ $IS_CURRENT_DIR -eq 1 ]; then
    while true; do
        read -p "请选择操作: 覆盖原文件(o) / 重命名导出文件(r) [默认覆盖]: " choice || true
        case "$choice" in
            o|O|overwrite|"") global_action="overwrite"; break ;;
            r|R|rename) global_action="rename"; break ;;
            *) echo "无效输入，请重新输入。" ;;
        esac
    done
else
    global_action="overwrite"
    echo "输出目录与源目录不同，自动使用覆盖模式（原文件保留）。"
fi

# 串行进度显示函数
show_progress_serial() {
    local file="$1"
    local file_dur="$2"
    local proc_dur="$3"
    local total_dur="$4"
    local start_ts="$5"
    local tmpfile="$6"

    if [ "$audio_codec" = "copy" ]; then
        audio_param="-c:a copy"
    else
        audio_param="-c:a $audio_codec"
    fi

    if [ "$is_nvenc" -eq 1 ]; then
        hw_param=""
        filter_param="-vf format=yuv420p"
    else
        if [ $hwaccel_available -eq 1 ]; then
            hw_param="-hwaccel cuda"
            filter_param="-vf format=$pix_fmt"
        else
            hw_param=""
            filter_param="-vf format=$pix_fmt"
        fi
    fi

    set +e
    ffmpeg $hw_param -threads auto -i "$file" \
        -c:v $video_codec \
        $filter_param \
        $audio_param \
        -y -stats \
        -progress pipe:1 \
        "$tmpfile" 2>&1 | awk -v file="$file" \
            -v file_dur="$file_dur" \
            -v proc_dur="$proc_dur" \
            -v total_dur="$total_dur" \
            -v start_ts="$start_ts" \
            -v tmp="$tmpfile" '
        BEGIN {
            printf "\n"
        }
        /^out_time_ms=/ {
            gsub(/out_time_ms=/, "");
            current_ms = $0;
            if (current_ms < 0) current_ms = 0;
            if (file_dur > 0) {
                file_progress = (current_ms / 1000) / file_dur * 100;
                if (file_progress > 100) file_progress = 100;
            } else {
                file_progress = 0;
            }
            overall_done = proc_dur + (file_progress / 100) * file_dur;
            if (overall_done > total_dur) overall_done = total_dur;
            overall_progress = (overall_done / total_dur) * 100;
            if (overall_progress > 100) overall_progress = 100;
            elapsed = systime() - start_ts;
            if (elapsed < 0) elapsed = 0;
            if (overall_progress > 0) {
                est_total = elapsed / (overall_progress / 100);
                est_remaining = est_total - elapsed;
                if (est_remaining < 0) est_remaining = 0;
            } else {
                est_remaining = 0;
            }
            rem_h = int(est_remaining / 3600);
            rem_m = int((est_remaining % 3600) / 60);
            rem_s = int(est_remaining % 60);
            rem_str = sprintf("%02d:%02d:%02d", rem_h, rem_m, rem_s);
            el_h = int(elapsed / 3600);
            el_m = int((elapsed % 3600) / 60);
            el_s = int(elapsed % 60);
            el_str = sprintf("%02d:%02d:%02d", el_h, el_m, el_s);
            bar_len = 50;
            filled = int(overall_progress / 100 * bar_len);
            if (filled > bar_len) filled = bar_len;
            bar = "";
            for (i=0; i<bar_len; i++) {
                if (i < filled) bar = bar "#";
                else bar = bar "-";
            }
            printf "\r[%s] %5.1f%%  已用: %s  剩余: %s  文件: %s",
                bar, overall_progress, el_str, rem_str, file;
            fflush(stdout);
        }
        !/^out_time_ms=/ && !/^progress=/ && !/^frame=/ && !/^fps=/ && !/^stream=/ && !/^speed=/ {
            print | "cat >&2"
        }
        END {
            printf "\n";
        }
        '
    ffmpeg_exit=${PIPESTATUS[0]}
    set -e
    return $ffmpeg_exit
}

# 并行处理函数
process_file_parallel() {
    local file="$1"
    local tmpfile="$2"
    local final_output="$3"
    local action="$4"
    local is_current_dir="$5"

    if [ "$audio_codec" = "copy" ]; then
        audio_param="-c:a copy"
    else
        audio_param="-c:a $audio_codec"
    fi

    if [ "$is_nvenc" -eq 1 ]; then
        hw_param=""
        filter_param="-vf format=yuv420p"
    else
        if [ $hwaccel_available -eq 1 ]; then
            hw_param="-hwaccel cuda"
            filter_param="-vf format=$pix_fmt"
        else
            hw_param=""
            filter_param="-vf format=$pix_fmt"
        fi
    fi

    local dur="${file_duration["$file"]}"
    if [ -z "$dur" ] || [ "$dur" = "0" ]; then
        dur=1
    fi

    set +e
    ffmpeg $hw_param -threads auto -nostdin -i "$file" \
        -c:v $video_codec \
        $filter_param \
        $audio_param \
        -y -stats \
        -progress pipe:1 \
        "$tmpfile" 2> >(cat >&2) | awk -v file="$file" -v dur="$dur" '
        BEGIN {
            printf "\r[%s] 0.0%%  ", file;
            fflush(stdout);
        }
        /^out_time_ms=/ {
            gsub(/out_time_ms=/, "");
            ms = $0;
            if (ms < 0) ms = 0;
            pct = (ms / 1000) / dur * 100;
            if (pct > 100) pct = 100;
            printf "\r[%s] %5.1f%%  ", file, pct;
            fflush(stdout);
        }
        END {
            printf "\r[%s] 100.0%% 完成\n", file;
        }
        '
    ffmpeg_exit=$?
    set -e

    if [ $ffmpeg_exit -eq 0 ] && [ -f "$tmpfile" ] && [ -s "$tmpfile" ]; then
        if [ "$action" = "overwrite" ] && [ $is_current_dir -eq 1 ]; then
            rm -f "$file"
            echo "  [OK] $file -> 已覆盖原文件"
        fi
        mv -f "$tmpfile" "$final_output"
        echo "  [OK] $file -> ${final_output##*/}"
        return 0
    else
        [ -f "$tmpfile" ] && rm -f "$tmpfile"
        echo "  [FAIL] $file (FFmpeg 退出码: $ffmpeg_exit, 输出文件异常)"
        return 1
    fi
}

# 主循环
processed=0
failed=0
processed_duration=0
global_start=$(date +%s)
total_files=${#files[@]}
current_num=0

if [ "$PARALLEL_JOBS" -eq 1 ]; then
    set +e
    for file in "${files[@]}"; do
        ((current_num++))
        echo "========================================="
        echo "处理第 $current_num / $total_files 个文件: $file"

        filename=$(basename -- "$file")
        basename_noext="${file%.*}"
        tmpfile="${OUTPUT_DIR}/${basename_noext}.tmp.${container}"
        final_output="${OUTPUT_DIR}/${basename_noext}.${container}"
        if [ "$global_action" = "rename" ]; then
            final_output="${OUTPUT_DIR}/${basename_noext}_Export.${container}"
        fi

        echo "正在转换: $filename -> ${final_output##*/}"
        echo "总体进度（所有文件）:"

        dur="${file_duration["$file"]}"
        show_progress_serial "$file" "$dur" "$processed_duration" "$total_duration" "$global_start" "$tmpfile"
        ffmpeg_exit=$?

        if [ $ffmpeg_exit -eq 0 ] && [ -f "$tmpfile" ] && [ -s "$tmpfile" ]; then
            if [ "$global_action" = "overwrite" ] && [ $IS_CURRENT_DIR -eq 1 ]; then
                rm -f "$file"
                echo "已删除原文件: $filename"
            fi
            mv -f "$tmpfile" "$final_output"
            echo "成功转换: $filename -> ${final_output##*/} (位置: $OUTPUT_DIR)"

            processed_duration=$(echo "$processed_duration + $dur" | bc 2>/dev/null || echo "$processed_duration")
            echo "累计已处理时长: $processed_duration 秒"

            if command -v ffprobe &> /dev/null; then
                echo "编码信息:"
                ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_name,codec_long_name,pix_fmt,profile \
                    -of default=noprint_wrappers=1 "$final_output" | sed 's/^/  /'
            fi
            processed=$((processed+1))
        else
            echo "转换失败: $filename (FFmpeg 返回码: $ffmpeg_exit)"
            [ -f "$tmpfile" ] && rm -f "$tmpfile"
            failed=$((failed+1))
        fi
        echo "已完成第 $current_num 个文件"
    done
    set -e
else
    echo "并行模式启动，同时处理 $PARALLEL_JOBS 个文件。"
    echo "每个文件显示独立进度行。"
    echo "----------------------------------------"

    pids=()
    for file in "${files[@]}"; do
        while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
            new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                else
                    wait "$pid" 2>/dev/null
                    status=$?
                    [ $status -eq 0 ] && processed=$((processed+1)) || failed=$((failed+1))
                fi
            done
            pids=("${new_pids[@]}")
            sleep 0.2
        done

        basename_noext="${file%.*}"
        tmpfile="${OUTPUT_DIR}/${basename_noext}.tmp.${container}"
        final_output="${OUTPUT_DIR}/${basename_noext}.${container}"
        if [ "$global_action" = "rename" ]; then
            final_output="${OUTPUT_DIR}/${basename_noext}_Export.${container}"
        fi

        process_file_parallel "$file" "$tmpfile" "$final_output" "$global_action" "$IS_CURRENT_DIR" &
        pids+=($!)
        echo "已启动转换: $file -> ${final_output##*/}"
        sleep 0.1
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
        status=$?
        [ $status -eq 0 ] && processed=$((processed+1)) || failed=$((failed+1))
    done
fi

echo "========================================="
echo "处理完成！成功: $processed, 失败: $failed"
