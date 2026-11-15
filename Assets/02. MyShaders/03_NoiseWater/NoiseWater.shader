// NoiseWater
// 갤러리 "물결 수면" + "클로킹 투명화(일렁이는 몸)"를 합친 물 셰이더.
//  - 물결 수면에서: 정점을 사인파 3개로 오르내리고, 같은 식의 기울기로 법선을 다시 구해 프레넬과 반사광을 칠한다.
//  - 클로킹에서:   물 아래(뒤) 화면을 파도 법선과 흐르는 노이즈만큼 비틀어 읽어, 바닥이 일렁여 보이게 한다.
//                 (원본 물결 수면은 반투명 섞기라 바닥이 휘지 않고 그대로 비친다)
Shader "MyShaders/NoiseWater"
{
    Properties
    {
        [Header(Waves)]
        _WaveHeight  ("Wave Height (0 = off)", Float) = 0
        _WaveLength  ("Wave Length", Float) = 2.2
        _WaveSpeed   ("Wave Speed", Float) = 0.8
        _WaveAngle   ("Wave Angle", Range(0, 360)) = 225

        [Header(Color)]
        _DeepColor   ("Deep Color", Color) = (0.016, 0.165, 0.271, 1)
        _SkyColor    ("Sky Color", Color) = (0.439, 0.643, 0.8, 1)
        _Murk        ("Water Murkiness", Range(0, 1)) = 0.35
        _SpecStrength("Specular Strength", Float) = 1.2
        _SpecPower   ("Specular Power", Float) = 200

        [Header(Shimmer)]
        _Refraction  ("Refraction Strength", Range(0, 0.2)) = 0.06
        _NoiseScale  ("Shimmer Noise Scale", Float) = 3
        _NoiseStrength("Shimmer Noise Strength", Range(0, 1)) = 0.5
        _FlowSpeed   ("Shimmer Flow Speed", Float) = 0.4
    }

    SubShader
    {
        // Transparent 큐: Opaque Texture(물 아래 바닥이 찍힌 화면)가 복사된 뒤에 그린다.
        Tags { "RenderPipeline" = "UniversalPipeline" "Queue" = "Transparent" "RenderType" = "Transparent" }

        Pass
        {
            Name "NoiseWater"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            ZWrite On
            Blend Off   // 물 아래 화면을 직접 읽어 칠하므로 섞지 않는다.

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float  _WaveHeight;
                float  _WaveLength;
                float  _WaveSpeed;
                float  _WaveAngle;
                float4 _DeepColor;
                float4 _SkyColor;
                float  _Murk;
                float  _SpecStrength;
                float  _SpecPower;
                float  _Refraction;
                float  _NoiseScale;
                float  _NoiseStrength;
                float  _FlowSpeed;
            CBUFFER_END

            #define TAU 6.2831853
            #define NOISE_PERIOD 64.0
            #define MAX_SHIFT 0.25

            // ===== 물결 수면 (갤러리 water-wave-surface) =====================
            // 파도 하나. x = 높이, y/z = 높이를 x, z 로 미분한 기울기.
            float3 WaveOne(float2 xz, float angleDeg, float lambda, float amp, float speed, float time)
            {
                float a = angleDeg * 0.0174533;
                float2 dir = float2(sin(a), cos(a));
                float k = TAU / lambda;
                float phase = k * dot(dir, xz) - TAU * frac(time * speed / lambda);
                float c = amp * k * cos(phase);
                return float3(amp * sin(phase), c * dir.x, c * dir.y);
            }

            // 방향, 파장, 높이가 다른 사인파 3개의 합.
            float3 WaveSum(float2 xz, float time)
            {
                float3 w = WaveOne(xz, _WaveAngle,        _WaveLength,        _WaveHeight,        _WaveSpeed,        time);
                w +=       WaveOne(xz, _WaveAngle + 55.0, _WaveLength * 0.77, _WaveHeight * 0.6,  _WaveSpeed * 0.88, time);
                w +=       WaveOne(xz, _WaveAngle - 40.0, _WaveLength * 0.58, _WaveHeight * 0.4,  _WaveSpeed * 0.76, time);
                return w;
            }

            // ===== 일렁임 노이즈 (갤러리 cloak-refraction-shimmer) ===========
            float Hash(float3 p)
            {
                p.y = p.y - NOISE_PERIOD * floor(p.y / NOISE_PERIOD);
                p = frac(p * 0.1031);
                p = p + dot(p, p.zyx + 31.32);
                return frac((p.x + p.y) * p.z);
            }

            float ValueNoise(float3 p)
            {
                float3 cell = floor(p);
                float3 f = frac(p);
                f = f * f * (3.0 - 2.0 * f);
                float x00 = lerp(Hash(cell + float3(0, 0, 0)), Hash(cell + float3(1, 0, 0)), f.x);
                float x10 = lerp(Hash(cell + float3(0, 1, 0)), Hash(cell + float3(1, 1, 0)), f.x);
                float x01 = lerp(Hash(cell + float3(0, 0, 1)), Hash(cell + float3(1, 0, 1)), f.x);
                float x11 = lerp(Hash(cell + float3(0, 1, 1)), Hash(cell + float3(1, 1, 1)), f.x);
                return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
            }

            // -1 ~ 1 로 넓힌 노이즈
            float Noise(float3 p)
            {
                float n = ValueNoise(p) * 0.7 + ValueNoise(p * 2.0 + float3(11.7, 0.0, 7.9)) * 0.3;
                return saturate((n - 0.2) / 0.6) * 2.0 - 1.0;
            }

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionOS : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
            };

            // ---- 정점 단계: 높이만 파도만큼 밀어 올린다 ----
            Varyings vert(Attributes v)
            {
                Varyings o;
                float3 pos = v.positionOS.xyz;
                pos.y += WaveSum(pos.xz, _Time.y).x;
                o.positionOS = pos;
                o.positionWS = TransformObjectToWorld(pos);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                return o;
            }

            half4 frag(Varyings i) : SV_Target
            {
                // ---- 1. 파도 법선: 높이 y = h(x, z) 인 면의 법선은 (-dh/dx, 1, -dh/dz) ----
                float3 w = WaveSum(i.positionOS.xz, _Time.y);
                float3 n = normalize(TransformObjectToWorldNormal(normalize(float3(-w.y, 1.0, -w.z))));
                float3 v = GetWorldSpaceNormalizeViewDir(i.positionWS);

                // ---- 2. 프레넬 + 반사광 (물결 수면 그대로) ----
                float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, v)), 5.0);
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(i.positionWS));
                float3 halfDir = normalize(mainLight.direction + v);
                float spec = pow(saturate(dot(n, halfDir)), _SpecPower) * _SpecStrength;
                float3 specColor = mainLight.color * mainLight.shadowAttenuation * spec;

                // ---- 3. 물 아래 일렁임 (클로킹의 일렁이는 몸을 응용) ----
                // 파도 법선을 카메라의 오른쪽/위 축에 내려 화면에서 미는 방향을 얻고,
                // 흐르는 노이즈를 더해 잔물결처럼 일렁이게 한다.
                float2 normalSS = float2(dot(n, UNITY_MATRIX_V[0].xyz), dot(n, UNITY_MATRIX_V[1].xyz));
                float flow = _Time.y * _FlowSpeed;
                flow = flow - NOISE_PERIOD * floor(flow / NOISE_PERIOD);
                float3 noisePos = i.positionOS * _NoiseScale - float3(0.0, flow, 0.0);
                float2 ripple = float2(Noise(noisePos), Noise(noisePos + float3(31.4, 0.0, 17.7)));
                float2 shift = (-normalSS + ripple * _NoiseStrength) * _Refraction;
                shift *= min(1.0, MAX_SHIFT / max(length(shift), 1e-5));   // 너무 멀리 읽지 않게

                // 화면 좌표 x 는 화면 폭 단위라 화면비만큼 줄인다 (16:9 에서 가로로 더 밀리지 않게)
                float2 screenUV = GetNormalizedScreenSpaceUV(i.positionCS);
                float2 offset = shift * float2(_ScreenParams.y / _ScreenParams.x, 1.0);
                float2 shiftedUV = saturate(screenUV + offset);

                // 앞 물체 끌림 방지: 밀린 자리의 씬이 수면보다 앞에 있으면 밀지 않은 자리를 읽는다.
                float selfEye  = i.positionCS.w;
                float sceneEye = LinearEyeDepth(SampleSceneDepth(shiftedUV), _ZBufferParams);
                shiftedUV = (sceneEye < selfEye) ? screenUV : shiftedUV;

                float3 underwater = SampleSceneColor(shiftedUV);
                underwater = lerp(underwater, _DeepColor.rgb, _Murk);   // 물빛으로 탁하게

                // ---- 4. 최종: 프레넬로 물 아래와 하늘빛을 섞고 반사광을 더한다 ----
                float3 color = lerp(underwater, _SkyColor.rgb, fresnel) + specColor;
                return half4(color, 1);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
