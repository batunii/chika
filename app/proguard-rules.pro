# Keep all JNI native method signatures (TFLite, 7-Zip-JBinding).
-keepclasseswithmembernames class * {
    native <methods>;
}

# 7-Zip-JBinding (JNI callbacks must be kept)
-keep class net.sf.sevenzipjbinding.** { *; }
-dontwarn net.sf.sevenzipjbinding.**

# commons-compress
-dontwarn org.apache.commons.compress.**

# TensorFlow Lite / LiteRT (same org.tensorflow.lite package)
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
-keep class com.google.ai.edge.litert.** { *; }
-dontwarn com.google.ai.edge.litert.**

# Keep annotation/signature metadata that Room and reflection-based code rely on.
-keepattributes Signature,InnerClasses,EnclosingMethod,RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations

# Strip info/debug/verbose logging from release builds (errors and warnings are kept).
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
