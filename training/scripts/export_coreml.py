#!/usr/bin/env python3
"""Export a trained .pt model to the Core ML package the Apple app (iOS, iPadOS, Mac Catalyst) loads.

Same model contract as the .tflite, so the shared YoloPanelDecoder consumes it unchanged:
  input  `image`  640×640 RGB image (Core ML scales pixels to 0–1, exactly like the tflite's float input)
  output `output` [1,300,6] float32 (x1,y1,x2,y2,score,cls in input pixels — end-to-end, no NMS needed)
Weights stay FP32. Core ML output matches the PyTorch model to 3 decimals; the Android int8 .tflite
differs only where quantization moves borderline scores across the 0.25 threshold.

The bundled upstream weights are leoxs22/manga-panel-detector-yolo26n (manga_panel_detector_fp32.pt).

Usage (coremltools needs numpy<=2.3.5 and torch<=2.7):
  pip install ultralytics coremltools "numpy<2.3" "torch==2.7.1" "torchvision==0.22.1"
  python export_coreml.py --weights manga_panel_detector_fp32.pt \
    --out ../iosApp/Sources/MangaPanelDetector.mlpackage
"""
import argparse, shutil


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", default="MangaPanelDetector.mlpackage")
    ap.add_argument("--imgsz", type=int, default=640)
    a = ap.parse_args()

    import coremltools as ct
    from ultralytics import YOLO

    # nms=False keeps YOLO26's end-to-end [1,300,6] head; Ultralytics applies its CoreML-specific
    # graph fixes (gather/attention) that a plain coremltools.convert of the TorchScript lacks.
    exported = YOLO(a.weights).export(format="coreml", imgsz=a.imgsz, nms=False)
    model = ct.models.MLModel(str(exported))
    spec = model.get_spec()
    ct.utils.rename_feature(spec, spec.description.output[0].name, "output")
    model = ct.models.MLModel(spec, weights_dir=model.weights_dir)
    shutil.rmtree(a.out, ignore_errors=True)
    model.save(a.out)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
