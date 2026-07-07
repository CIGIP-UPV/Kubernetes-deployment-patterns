from launch import LaunchDescription
from launch_ros.actions import Node
import os


def generate_launch_description():
    return LaunchDescription([
        Node(
            package='llava_pkg',
            executable='llava_node',
            name='llava_node',
            output='screen',
            parameters=[{
                'model_id':            os.environ.get('LLAVA_MODEL_ID',        'llava-hf/llava-1.5-7b-hf'),
                'image_topic':         os.environ.get('LLAVA_IMAGE_TOPIC',     '/camera/image/compressed'),
                'detection_topic':     os.environ.get('YOLO_DETECTIONS_TOPIC', '/detections'),
                'trigger_topic':       os.environ.get('LLAVA_TRIGGER_TOPIC',   '/llava/trigger'),
                'response_topic':      os.environ.get('LLAVA_RESPONSE_TOPIC',  '/llava/response'),
                'latency_topic':       os.environ.get('LLAVA_LATENCY_TOPIC',   '/llava/metrics_latency_ms'),
                'inference_topic':     os.environ.get('LLAVA_INFERENCE_TOPIC', '/llava/metrics_inference_ms'),
                'trigger_on_yolo':     os.environ.get('LLAVA_TRIGGER_ON_YOLO', 'true').lower() == 'true',
                'yolo_trigger_interval_s': float(os.environ.get('LLAVA_YOLO_INTERVAL_S', '8.0')),
                'max_new_tokens':      int(os.environ.get('LLAVA_MAX_TOKENS',  '150')),
                'load_in_4bit':        os.environ.get('LLAVA_LOAD_4BIT', 'true').lower() == 'true',
                'hf_cache_dir':        os.environ.get('HF_HOME', '/opt/huggingface_cache'),
            }],
        ),
    ])
