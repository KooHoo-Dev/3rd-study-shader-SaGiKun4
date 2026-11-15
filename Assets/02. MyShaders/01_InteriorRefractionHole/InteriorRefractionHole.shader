// InteriorRefractionHole
// 인테리어 매핑(광선-도형 교차) + 씬 컬러 굴절을 합친 셰이더.
// 오브젝트 중심을 지나 한 축(_TubeAxis)으로 뚫린 "원통 구멍" 하나가 있다고 가정한다.
//  - 광선이 원통 벽에 먼저 닿으면 → 벽을 칠한다 (인테리어 매핑)
//  - 벽에 닿기 전에 구멍 끝(출구)을 지나면 → 뒤쪽 씬 컬러를 칠한다 (굴절 유리)
// UV나 탄젠트를 쓰지 않고 오브젝트 공간 좌표만 쓰므로 어떤 메시에도 붙일 수 있다.
Shader "MyShaders/InteriorRefractionHole"
{
    Properties
    {
        [Header(Hole)]
        _Radius     ("Hole Radius (object units)", Float) = 0.28
        _Depth      ("Tunnel Length (object units)", Float) = 0.9
        _TubeAxis   ("Tunnel Axis (object space)", Vector) = (0, 0, 1, 0)

        [Header(Exit Glass)]
        _Refraction ("Refraction Strength", Range(0, 0.1)) = 0.02
        [HDR] _ExitRim ("Exit Edge Glow", Color) = (0.3, 0.8, 1.5, 1)
    }

    SubShader
    {
        // Transparent 큐: Opaque Texture가 복사된 "뒤"에 그려야 뒤쪽 씬을 샘플링할 수 있다.
        Tags { "RenderPipeline" = "UniversalPipeline" "Queue" = "Transparent" "RenderType" = "Transparent" }

        Pass
        {
            Name "InteriorRefractionHole"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            ZWrite On
            Blend Off   // 뒤 화면을 직접 샘플링해서 칠하므로 알파 블렌딩이 필요 없다.

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float  _Radius;
                float  _Depth;
                float4 _TubeAxis;
                float  _Refraction;
                float4 _ExitRim;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionOS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.positionOS = v.positionOS.xyz;
                o.normalWS   = TransformObjectToWorldNormal(v.normalOS);
                return o;
            }

            // 램버트 + 환경광(SH). 표면과 터널 벽에 공통으로 쓴다.
            float3 Shade(float3 normalWS, float3 albedo)
            {
                Light mainLight = GetMainLight();
                float  ndotl = saturate(dot(normalWS, mainLight.direction));
                return albedo * (mainLight.color * ndotl + SampleSH(normalWS));
            }

            half4 frag(Varyings i) : SV_Target
            {
                // ---- 1. 터널 좌표계 만들기 ----------------------------------
                // a = 구멍이 뚫린 방향, u/v = 그에 수직인 단면 방향
                float3 a = normalize(_TubeAxis.xyz + 1e-5);
                float3 helper = abs(a.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
                float3 u = normalize(cross(helper, a));
                float3 v = cross(a, u);
                float3x3 toTube = float3x3(u, v, a);   // 오브젝트 → 터널 공간 (직교 행렬)

                // ---- 2. 시선 광선 (오브젝트 공간) ----------------------------
                float3 camOS = TransformWorldToObject(_WorldSpaceCameraPos);
                float3 dirOS = normalize(i.positionOS - camOS);  // 카메라 → 표면 → 안쪽
                float3 p = mul(toTube, i.positionOS);
                float3 d = mul(toTube, dirOS);

                // ---- 3. 구멍 안인가? -----------------------------------------
                // 단면(xy)에서 중심까지 거리가 반지름보다 크면 → 막힌 표면
                if (dot(p.xy, p.xy) > _Radius * _Radius)
                    return half4(Shade(normalize(i.normalWS), float3(1, 1, 1)), 1);   // 표면색: 흰색 고정

                // ---- 4. 광선-원통 교차 (인테리어 매핑의 핵심) ----------------
                // |p.xy + d.xy * t| = R 을 t에 대해 푼다 (2차 방정식, 안쪽에서 출발하므로 큰 근)
                float A = max(dot(d.xy, d.xy), 1e-8);
                float B = dot(p.xy, d.xy);
                float C = dot(p.xy, p.xy) - _Radius * _Radius;   // 구멍 안이므로 C <= 0
                float tWall = (-B + sqrt(max(B * B - A * C, 0.0))) / A;

                // 출구: 오브젝트 중심에서 ±_Depth/2 떨어진 평면 중 광선이 향하는 쪽
                float dz    = (abs(d.z) < 1e-5) ? 1e-5 : d.z;
                float zExit = (dz > 0 ? 0.5 : -0.5) * _Depth;
                float tExit = (zExit - p.z) / dz;

                if (tWall < tExit)
                {
                    // ---- 5a. 원통 벽에 먼저 닿음 → 터널 벽 칠하기 ------------
                    float3 hitT  = p + d * tWall;
                    float3 nTube = float3(-normalize(hitT.xy), 0);   // 벽 노멀은 중심 쪽을 향함
                    float3 nWS   = TransformObjectToWorldNormal(mul(nTube, toTube));

                    // 0 = 구멍 입구 쪽, 1 = 출구 쪽 (출구까지 남은 비율)
                    float depth01 = saturate(1.0 - abs(zExit - hitT.z) / _Depth);
                    float3 albedo = float3(1, 1, 1);   // 벽색: 흰색 고정

                    // 깊이 어둡기 1 고정: 깊어질수록 선형으로 검게
                    float3 col = Shade(nWS, albedo) * (1.0 - depth01);
                    return half4(col, 1);
                }

                // ---- 5b. 출구에 도달 → 뒤쪽 씬 컬러 샘플링 ------------------
                // 출구 지점은 카메라 → 이 픽셀 직선 위에 있으므로 화면에서는 이 픽셀과 같은 위치다.
                // 유리 없는 구멍은 시선 그대로 똑바로 뒤가 보이므로, 이 픽셀의 화면 좌표를 그대로 쓴다.
                float2 screenUV = GetNormalizedScreenSpaceUV(i.positionCS);

                // 굴절: 표면 노멀의 화면 방향 성분만큼 UV를 비튼다.
                float3 nVS = TransformWorldToViewDir(normalize(i.normalWS), true);
                screenUV += nVS.xy * _Refraction;

                float3 sceneCol = SampleSceneColor(saturate(screenUV));   // 유리 틴트 없음 (흰색 = 원래 색 그대로)

                // 출구 가장자리 발광: 출구 지점이 원통 벽에 얼마나 가까운지
                float2 exitXY = (p + d * tExit).xy;
                float  edge = (_Radius - length(exitXY)) / _Radius;
                sceneCol += _ExitRim.rgb * (1.0 - smoothstep(0.0, 0.08, edge));

                return half4(sceneCol, 1);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
