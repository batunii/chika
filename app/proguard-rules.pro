# OpenCV uses JNI; keep its classes and native methods.
-keep class org.opencv.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# 7-Zip-JBinding (JNI callbacks must be kept)
-keep class net.sf.sevenzipjbinding.** { *; }
-dontwarn net.sf.sevenzipjbinding.**

# commons-compress
-dontwarn org.apache.commons.compress.**

# TensorFlow Lite
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
