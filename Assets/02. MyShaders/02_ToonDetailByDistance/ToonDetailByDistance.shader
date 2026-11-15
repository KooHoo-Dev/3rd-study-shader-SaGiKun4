// ToonDetailByDistance
// 갤러리 "램프 툰 조명"을 바탕으로, 카메라 거리에 따라 띠 수와 경계 부드러움을 바꾼다.
//  - 가까우면: 띠가 많고 경계가 부드러워 실사에 가까운 음영
//  - 멀면:     띠가 적고 경계가 딱 끊겨 툰 음영
// 최적화 LOD("멀면 단순하게")에서 착안한 연출이다. 단, 셰이더 연산량 자체는 거리와 상관없이 같다.
Shader "MyShaders/ToonDetailByDistance"
{
    Properties
    {
        [Header(Color)]
        _BaseColor   ("Base Color", Color) = (0.949, 0.706, 0.549, 1)
        _ShadeColor  ("Shade Color", Color) = (0.604, 0.533, 0.847, 1)

        [Header(Distance)]
        _NearDist    ("Near Distance", Float) = 1.5
        _FarDist     ("Far Distance", Float) = 6

        [Header(Near Style  realistic)]
        _NearBands   ("Near Bands", Range(2, 8)) = 8
        _NearSoftness("Near Softness", Range(0, 0.5)) = 0.5

        [Header(Far Style  toon)]
        _FarBands    ("Far Bands", Range(2, 8)) = 2
        _FarSoftness ("Far Softness", Range(0, 0.5)) = 0.02
    }

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" "RenderType" = "Opaque" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseColor;
            float4 _ShadeColor;
            float  _NearDist;
            float  _FarDist;
            float  _NearBands;
            float  _NearSoftness;
            float  _FarBands;
            float  _FarSoftness;
        CBUFFER_END
        ENDHLSL

        Pass
        {
            Name "Forward"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            // 받는 그림자: 이 키워드가 있어야 GetMainLight 가 그림자 맵을 읽는다.
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionWS = TransformObjectToWorld(v.positionOS.xyz);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                o.normalWS   = TransformObjectToWorldNormal(v.normalOS);
                return o;
            }

            // 0~1 밝기를 bands 개의 띠로 끊는다 (갤러리 toonBands 와 같은 식).
            // softness 는 띠 하나 폭에 대한 경계 폭 비율. 0.5 면 띠 사이가 완전히 이어진다.
            float ToonBands(float level, float bands, float softness)
            {
                bands = max(floor(bands + 0.5), 2.0);      // 띠 수는 정수로: 거리에 따라 단계적으로 바뀐다
                float t    = level * bands - 0.5;
                float cell = floor(t);
                float f    = t - cell;
                float w    = clamp(max(softness, fwidth(t)), 0.001, 0.5);
                float stepped = cell + smoothstep(0.5 - w, 0.5 + w, f);
                return saturate(stepped / (bands - 1.0));
            }

            half4 frag(Varyings i) : SV_Target
            {
                // ---- 1. 거리 → 스타일 비율 (가까우면 0, 멀면 1) ----------------
                // 픽셀마다가 아니라 물체 중심 하나로 재서, 물체 전체가 같은 스타일이 되게 한다.
                float3 centerWS = TransformObjectToWorld(float3(0, 0, 0));
                float  dist = distance(_WorldSpaceCameraPos, centerWS);
                float  farT = saturate((dist - _NearDist) / max(_FarDist - _NearDist, 0.001));

                float bands    = lerp(_NearBands,    _FarBands,    farT);
                float softness = lerp(_NearSoftness, _FarSoftness, farT);

                // ---- 2. 밝기: dot(N, L) x 받는 그림자 ------------------------
                float3 n = normalize(i.normalWS);
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(i.positionWS));
                float level = saturate(dot(n, mainLight.direction)) * mainLight.shadowAttenuation;

                // ---- 3. 띠로 끊고, 그늘 색과 기본 색 사이를 고른다 -------------
                float band = ToonBands(level, bands, softness);
                float3 tint = lerp(_ShadeColor.rgb, float3(1, 1, 1), band);
                return half4(_BaseColor.rgb * tint, 1);
            }
            ENDHLSL
        }

        // 그림자 드리우기
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vertShadow
            #pragma fragment fragShadow
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            float4 vertShadow(Attributes v) : SV_POSITION
            {
                float3 positionWS = TransformObjectToWorld(v.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(v.normalOS);
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDir = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDir = _LightDirection;
                #endif
                float4 cs = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDir));
                return ApplyShadowClamping(cs);
            }

            half4 fragShadow() : SV_Target { return 0; }
            ENDHLSL
        }

        // 깊이 텍스처에 기록 (1번 셰이더의 Opaque Texture 등 다른 효과와 맞물리도록)
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On
            ColorMask R

            HLSLPROGRAM
            #pragma vertex vertDepth
            #pragma fragment fragDepth

            float4 vertDepth(float4 positionOS : POSITION) : SV_POSITION
            {
                return TransformObjectToHClip(positionOS.xyz);
            }

            half4 fragDepth() : SV_Target { return 0; }
            ENDHLSL
        }
    }
    FallBack Off
}
