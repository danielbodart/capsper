"""PyTorch wrapper modules for CoreML export.

Two wrappers:
1. EncoderWrapper — streaming FastConformer with explicit cache I/O
2. FusedDecoderJointWrapper — RNNT prediction LSTM + joiner in one forward pass
"""
from __future__ import annotations

from typing import Tuple

import torch
import torch.nn as nn


class EncoderWrapper(nn.Module):
    """Streaming FastConformer encoder with explicit cache I/O.

    NeMo uses layer-first cache layout [L, B, ...] internally, but we expose
    batch-first [B, L, ...] for CoreML (transposing in/out of the NeMo call).
    """

    def __init__(self, encoder: nn.Module, total_mel_frames: int = 65):
        super().__init__()
        self.encoder = encoder
        self.total_mel_frames = total_mel_frames

    def forward(
        self,
        audio_signal: torch.Tensor,
        cache_last_channel: torch.Tensor,
        cache_last_time: torch.Tensor,
        cache_last_channel_len: torch.Tensor,
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Args:
            audio_signal: mel [1, 128, 65]
            cache_last_channel: [1, 24, 70, 1024] (batch-first)
            cache_last_time: [1, 24, 1024, 8] (batch-first)
            cache_last_channel_len: [1]

        Returns:
            encoded: [1, 1024, T_out]
            encoded_length: [1] int32
            cache_channel_out: [1, 24, 70, 1024]
            cache_time_out: [1, 24, 1024, 8]
            cache_len_out: [1] int32
        """
        length = torch.tensor(
            [self.total_mel_frames], dtype=torch.long, device=audio_signal.device
        )

        # Transpose to NeMo's layer-first [L, B, ...]
        cache_ch = cache_last_channel.transpose(0, 1).contiguous()
        cache_time = cache_last_time.transpose(0, 1).contiguous()
        cache_len = cache_last_channel_len.to(dtype=torch.long)

        encoded, encoded_lengths, new_ch, new_time, new_ch_len = self.encoder(
            audio_signal=audio_signal,
            length=length,
            cache_last_channel=cache_ch,
            cache_last_time=cache_time,
            cache_last_channel_len=cache_len,
        )

        # Transpose back to batch-first [B, L, ...]
        return (
            encoded,
            encoded_lengths.to(dtype=torch.int32),
            new_ch.transpose(0, 1).contiguous(),
            new_time.transpose(0, 1).contiguous(),
            new_ch_len.to(dtype=torch.int32),
        )


class FusedDecoderJointWrapper(nn.Module):
    """Fused RNNT prediction network (LSTM) + joint network.

    Single forward pass: encoder frame + token + LSTM state -> logits + new state.
    Matches the existing Zig ONNX decoder session interface exactly.
    """

    def __init__(self, decoder: nn.Module, joint: nn.Module):
        super().__init__()
        self.decoder = decoder
        self.joint = joint

    def forward(
        self,
        encoder_outputs: torch.Tensor,  # [1, D_enc, 1]
        targets: torch.Tensor,          # [1, 1] int32
        target_length: torch.Tensor,    # [1] int32
        input_states_1: torch.Tensor,   # [num_layers, 1, hidden] LSTM h
        input_states_2: torch.Tensor,   # [num_layers, 1, hidden] LSTM c
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Returns:
            logits: [1, vocab_size+1] (1025 for Nemotron)
            output_states_1: [num_layers, 1, hidden] new LSTM h
            output_states_2: [num_layers, 1, hidden] new LSTM c
        """
        states = [input_states_1, input_states_2]
        decoder_output, _, new_states = self.decoder(
            targets=targets.to(dtype=torch.long),
            target_length=target_length.to(dtype=torch.long),
            states=states,
        )

        # NeMo joint expects [B, T, D] -- transpose from [B, D, T]
        enc_for_joint = encoder_outputs.transpose(1, 2)  # [1, 1, D_enc]
        dec_for_joint = decoder_output.transpose(1, 2)    # [1, 1, D_dec]

        enc_proj = self.joint.enc(enc_for_joint)   # [1, 1, joint_dim]
        dec_proj = self.joint.pred(dec_for_joint)   # [1, 1, joint_dim]

        # Broadcasting: [1, 1, 1, joint_dim]
        combined = enc_proj.unsqueeze(2) + dec_proj.unsqueeze(1)

        # joint_net: ReLU -> Dropout -> Linear -> logits
        for layer in self.joint.joint_net:
            combined = layer(combined)

        # [1, 1, 1, vocab_size+1] -> [1, vocab_size+1]
        logits = combined.squeeze(1).squeeze(1)

        return logits, new_states[0], new_states[1]
