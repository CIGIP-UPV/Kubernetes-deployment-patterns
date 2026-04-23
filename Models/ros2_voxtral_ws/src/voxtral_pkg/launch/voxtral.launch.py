from launch import LaunchDescription
from launch_ros.actions import Node
import os


def generate_launch_description():
    return LaunchDescription([
        Node(
            package='voxtral_pkg',
            executable='voxtral_node',
            name='voxtral_node',
            output='screen',
            parameters=[{
                'audio_mode':           os.environ.get('VOXTRAL_AUDIO_MODE', 'false').lower() == 'true',
                'model_id':             os.environ.get('VOXTRAL_MODEL_ID',   'mistralai/Voxtral-Mini-3B-2507'),
                'command_topic':        os.environ.get('VOICE_COMMAND_TOPIC',        '/voice/command'),
                'transcript_topic':     os.environ.get('VOICE_TRANSCRIPT_TOPIC',     '/voice/transcript'),
                'response_topic':       os.environ.get('VOICE_RESPONSE_TOPIC',       '/voice/response'),
                'llava_trigger_topic':  os.environ.get('LLAVA_TRIGGER_TOPIC',        '/llava/trigger'),
                'llava_response_topic': os.environ.get('LLAVA_RESPONSE_TOPIC',       '/llava/response'),
                'latency_topic':        os.environ.get('VOICE_LATENCY_TOPIC',        '/voice/metrics_latency_ms'),
                'hf_cache_dir':         os.environ.get('HF_HOME',                    '/opt/huggingface_cache'),
            }],
        ),
    ])
