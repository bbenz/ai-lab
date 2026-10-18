"""Batch sentiment classification for the LAB723 Ray exercise.

The Ray image includes this module and the model files, so each Ray worker loads the model from its own disk. The
notebook sends the reviews in chunks, and each worker classifies a whole chunk in one model call.
"""

import json
import os

import numpy as np

MODEL_DIR = os.environ.get("LAB723_MODEL_DIR", "/home/ray/model")


class BatchModel:
    """The ONNX model and tokenizer, set up to classify a list of texts at a time."""

    def __init__(self, model_dir=MODEL_DIR, threads=1):
        import onnxruntime as ort
        from tokenizers import Tokenizer

        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        self.session = ort.InferenceSession(os.path.join(model_dir, "model.onnx"), options,
                                            providers=["CPUExecutionProvider"])
        self.tokenizer = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=128)
        self.tokenizer.enable_padding(pad_id=0, pad_token="[PAD]")  # Pads each chunk to its longest text
        with open(os.path.join(model_dir, "config.json"), encoding="utf-8") as stream:
            config = json.load(stream)
        self.labels = {int(key): value for key, value in config["id2label"].items()}

    def classify(self, texts):
        encodings = self.tokenizer.encode_batch(list(texts))
        feeds = {
            "input_ids": np.asarray([encoding.ids for encoding in encodings], dtype=np.int64),
            "attention_mask": np.asarray([encoding.attention_mask for encoding in encodings], dtype=np.int64),
        }
        logits = self.session.run(["logits"], feeds)[0]
        exponentials = np.exp(logits - logits.max(axis=1, keepdims=True))
        probabilities = exponentials / exponentials.sum(axis=1, keepdims=True)
        return [
            {"label": self.labels[int(index)], "score": round(float(row[index]), 4)}
            for row, index in zip(probabilities, probabilities.argmax(axis=1))
        ]
