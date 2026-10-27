#version 300 es
precision highp float;
precision highp int;

uniform highp vec4 uData[57];
uniform highp sampler2D uSampler;
uniform highp sampler2D uTex1;

in highp vec4 vColor;
in highp vec2 vTextureCoord;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _933;
    do
    {
        int _104 = int((vColor.y * 255.0) + 0.5);
        int _109 = int((vColor.z * 255.0) + 0.5);
        bool _129 = uData[5].y > 0.0;
        highp vec2 _131;
        highp float _134;
        highp vec2 _136;
        highp vec4 _138;
        highp vec2 _140;
        highp float _142;
        highp float _144;
        highp vec2 _146;
        highp vec4 _148;
        highp float _150;
        highp float _152;
        highp float _154;
        _131 = vec2(0.0, 1.0);
        _134 = 1000000000.0;
        _136 = vec2(0.0);
        _138 = vec4(0.0);
        _140 = vec2(0.0);
        _142 = 1000000000.0;
        _144 = 1000000000.0;
        _146 = vec2(0.0, 1.0);
        _148 = vec4(0.0);
        _150 = 1000000000.0;
        _152 = 1000000000.0;
        _154 = 1000000000.0;
        highp vec2 _141;
        highp float _145;
        highp vec4 _149;
        highp float _153;
        highp float _155;
        highp vec2 _132;
        highp float _135;
        highp vec2 _137;
        highp vec4 _139;
        highp float _143;
        highp vec2 _147;
        highp float _151;
        int _156 = _104;
        for (;;)
        {
            bool _165;
            if (_156 < (_104 + _109))
            {
                _165 = _156 < 16;
            }
            else
            {
                _165 = false;
            }
            if (_165)
            {
                int _167 = 3 * _156;
                int _168 = 9 + _167;
                int _174 = _167 + 11;
                highp vec2 _178 = vTextureCoord - uData[_168 * 1 + 0].xy;
                highp float _182 = min(uData[_168 * 1 + 0].z, uData[_168 * 1 + 0].w);
                highp vec4 _184 = min(uData[(_167 + 10) * 1 + 0], vec4(_182));
                highp float _185 = _178.x;
                highp float _206;
                if (_185 > 0.0)
                {
                    highp float _197;
                    if (_178.y > 0.0)
                    {
                        _197 = _184.z;
                    }
                    else
                    {
                        _197 = _184.y;
                    }
                    _206 = _197;
                }
                else
                {
                    highp float _205;
                    if (_178.y > 0.0)
                    {
                        _205 = _184.w;
                    }
                    else
                    {
                        _205 = _184.x;
                    }
                    _206 = _205;
                }
                highp vec2 _210 = (abs(_178) - uData[_168 * 1 + 0].zw) + vec2(_206);
                highp float _212 = (_185 < 0.0) ? (-1.0) : 1.0;
                highp float _215 = (_178.y < 0.0) ? (-1.0) : 1.0;
                highp float _217 = _210.x;
                bool _223;
                if (_217 > 0.0)
                {
                    _223 = _210.y > 0.0;
                }
                else
                {
                    _223 = false;
                }
                highp vec2 _237;
                if (_223)
                {
                    _237 = normalize(_210) * vec2(_212, _215);
                }
                else
                {
                    highp vec2 _236;
                    if (_217 > _210.y)
                    {
                        _236 = vec2(_212, 0.0);
                    }
                    else
                    {
                        _236 = vec2(0.0, _215);
                    }
                    _237 = _236;
                }
                highp float _244 = (min(max(_217, _210.y), 0.0) + length(max(_210, vec2(0.0)))) - _206;
                bool _245 = _244 < _152;
                if (_245)
                {
                    _132 = _146;
                    _135 = _154;
                    _139 = _148;
                    _147 = uData[_168 * 1 + 0].yw;
                    _151 = _152;
                }
                else
                {
                    bool _250 = _244 < _150;
                    highp vec2 _254;
                    if (_250)
                    {
                        _254 = uData[_168 * 1 + 0].yw;
                    }
                    else
                    {
                        _254 = _131;
                    }
                    bvec4 _256 = bvec4(_250);
                    _132 = _254;
                    _135 = _250 ? _182 : _134;
                    _139 = vec4(_256.x ? uData[_174 * 1 + 0].x : _138.x, _256.y ? uData[_174 * 1 + 0].y : _138.y, _256.z ? uData[_174 * 1 + 0].z : _138.z, _256.w ? uData[_174 * 1 + 0].w : _138.w);
                    _147 = _146;
                    _151 = _250 ? _244 : _150;
                }
                bvec4 _259 = bvec4(_245);
                _149 = vec4(_259.x ? uData[_174 * 1 + 0].x : _148.x, _259.y ? uData[_174 * 1 + 0].y : _148.y, _259.z ? uData[_174 * 1 + 0].z : _148.z, _259.w ? uData[_174 * 1 + 0].w : _148.w);
                _153 = _245 ? _244 : _152;
                _155 = _245 ? _182 : _154;
                highp vec2 _304;
                highp float _305;
                if (uData[_174 * 1 + 0].w < 0.5)
                {
                    highp float _270 = (vTextureCoord.x - uData[_168 * 1 + 0].x) + uData[_168 * 1 + 0].z;
                    highp float _272 = (uData[_168 * 1 + 0].x + uData[_168 * 1 + 0].z) - vTextureCoord.x;
                    highp float _277 = (vTextureCoord.y - uData[_168 * 1 + 0].y) + uData[_168 * 1 + 0].w;
                    highp float _279 = (uData[_168 * 1 + 0].y + uData[_168 * 1 + 0].w) - vTextureCoord.y;
                    highp float _283 = min(min(_270, _272), min(_277, _279));
                    highp vec4 _288 = exp((vec4(_283) - vec4(_270, _272, _277, _279)) / vec4(uData[1].y));
                    highp float _289 = _288.x;
                    highp float _290 = _288.y;
                    highp float _292 = _288.z;
                    highp float _294 = _288.w;
                    highp float _295 = ((_289 + _290) + _292) + _294;
                    _304 = vec2(_290 - _289, _294 - _292) / vec2(_295);
                    _305 = (uData[1].y * log(_295)) - _283;
                }
                else
                {
                    _304 = _237;
                    _305 = _244;
                }
                bool _306 = _305 < _144;
                if (_306)
                {
                    _137 = _140;
                    _143 = _144;
                }
                else
                {
                    bool _310 = _305 < _142;
                    bvec2 _311 = bvec2(_310);
                    _137 = vec2(_311.x ? _304.x : _136.x, _311.y ? _304.y : _136.y);
                    _143 = _310 ? _305 : _142;
                }
                bvec2 _314 = bvec2(_306);
                _141 = vec2(_314.x ? _304.x : _140.x, _314.y ? _304.y : _140.y);
                _145 = _306 ? _305 : _144;
                _131 = _132;
                _134 = _135;
                _136 = _137;
                _138 = _139;
                _140 = _141;
                _142 = _143;
                _144 = _145;
                _146 = _147;
                _148 = _149;
                _150 = _151;
                _152 = _153;
                _154 = _155;
                _156++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _320 = uData[56].w > 2.5;
        bool _321 = uData[56].w > 1.5;
        highp float _394;
        highp vec2 _395;
        if (_321)
        {
            highp vec2 _327 = vTextureCoord - uData[54].xy;
            highp vec4 _333 = min(uData[55], vec4(min(uData[54].z, uData[54].w)));
            highp float _334 = _327.x;
            highp float _355;
            if (_334 > 0.0)
            {
                highp float _346;
                if (_327.y > 0.0)
                {
                    _346 = _333.z;
                }
                else
                {
                    _346 = _333.y;
                }
                _355 = _346;
            }
            else
            {
                highp float _354;
                if (_327.y > 0.0)
                {
                    _354 = _333.w;
                }
                else
                {
                    _354 = _333.x;
                }
                _355 = _354;
            }
            highp vec2 _359 = (abs(_327) - uData[54].zw) + vec2(_355);
            highp float _361 = (_334 < 0.0) ? (-1.0) : 1.0;
            highp float _364 = (_327.y < 0.0) ? (-1.0) : 1.0;
            highp float _366 = _359.x;
            bool _372;
            if (_366 > 0.0)
            {
                _372 = _359.y > 0.0;
            }
            else
            {
                _372 = false;
            }
            highp vec2 _386;
            if (_372)
            {
                _386 = normalize(_359) * vec2(_361, _364);
            }
            else
            {
                highp vec2 _385;
                if (_366 > _359.y)
                {
                    _385 = vec2(_361, 0.0);
                }
                else
                {
                    _385 = vec2(0.0, _364);
                }
                _386 = _385;
            }
            _394 = (min(max(_366, _359.y), 0.0) + length(max(_359, vec2(0.0)))) - _355;
            _395 = _386;
        }
        else
        {
            _394 = -1000000000.0;
            _395 = vec2(0.0);
        }
        bool _399;
        if (_321)
        {
            _399 = !_320;
        }
        else
        {
            _399 = false;
        }
        highp vec2 _439;
        highp vec2 _440;
        highp float _441;
        highp vec2 _442;
        highp vec2 _443;
        highp vec4 _444;
        highp vec4 _445;
        highp float _446;
        highp float _447;
        highp float _448;
        highp float _449;
        if (_399)
        {
            highp float _402 = 1.0 - _394;
            bool _403 = _402 < _152;
            highp vec2 _417;
            highp vec2 _418;
            highp float _419;
            highp vec4 _420;
            highp float _421;
            if (_403)
            {
                _417 = _146;
                _418 = uData[54].yw;
                _419 = _154;
                _420 = _148;
                _421 = _152;
            }
            else
            {
                bool _408 = _402 < _150;
                highp vec2 _412;
                if (_408)
                {
                    _412 = uData[54].yw;
                }
                else
                {
                    _412 = _131;
                }
                bvec4 _414 = bvec4(_408);
                _417 = _412;
                _418 = _146;
                _419 = _408 ? _154 : _134;
                _420 = vec4(_414.x ? uData[56].x : _138.x, _414.y ? uData[56].y : _138.y, _414.z ? uData[56].z : _138.z, _414.w ? uData[56].w : _138.w);
                _421 = _408 ? _402 : _150;
            }
            bvec4 _422 = bvec4(_403);
            highp vec2 _425 = -_395;
            bool _426 = _402 < _144;
            highp vec2 _434;
            highp float _435;
            if (_426)
            {
                _434 = _140;
                _435 = _144;
            }
            else
            {
                bool _430 = _402 < _142;
                bvec2 _431 = bvec2(_430);
                _434 = vec2(_431.x ? _425.x : _136.x, _431.y ? _425.y : _136.y);
                _435 = _430 ? _402 : _142;
            }
            bvec2 _436 = bvec2(_426);
            _439 = _417;
            _440 = _418;
            _441 = _419;
            _442 = _434;
            _443 = vec2(_436.x ? _425.x : _140.x, _436.y ? _425.y : _140.y);
            _444 = _420;
            _445 = vec4(_422.x ? uData[56].x : _148.x, _422.y ? uData[56].y : _148.y, _422.z ? uData[56].z : _148.z, _422.w ? uData[56].w : _148.w);
            _446 = _435;
            _447 = _426 ? _402 : _144;
            _448 = _421;
            _449 = _403 ? _402 : _152;
        }
        else
        {
            _439 = _131;
            _440 = _146;
            _441 = _134;
            _442 = _136;
            _443 = _140;
            _444 = _138;
            _445 = _148;
            _446 = _142;
            _447 = _144;
            _448 = _150;
            _449 = _152;
        }
        highp float _451 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _456 = max(_451 - abs(_449 - _448), 0.0) / _451;
        highp float _457 = _456 * _456;
        highp float _458 = _457 * 0.5;
        highp float _463;
        if (_448 < _449)
        {
            _463 = 1.0 - _458;
        }
        else
        {
            _463 = _458;
        }
        highp float _467 = min(_449, _448) - ((_457 * _451) * 0.25);
        highp float _472 = max(_451 - abs(_447 - _446), 0.0) / _451;
        highp float _473 = _472 * _472;
        highp float _474 = _473 * 0.5;
        highp float _479;
        if (_446 < _447)
        {
            _479 = 1.0 - _474;
        }
        else
        {
            _479 = _474;
        }
        highp float _483 = min(_447, _446) - ((_473 * _451) * 0.25);
        highp float _487;
        if (_320)
        {
            _487 = max(_467, _394);
        }
        else
        {
            _487 = _467;
        }
        highp float _490 = clamp(0.5 - max(_487, _394), 0.0, 1.0);
        if (_490 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _933 = vec4(0.0, 0.0, 0.0, _490);
            break;
        }
        highp vec4 _501 = mix(_445, _444, vec4(_463));
        highp vec2 _503 = mix(_443, _442, vec2(_479));
        bool _507;
        if (_320)
        {
            _507 = _394 > _483;
        }
        else
        {
            _507 = false;
        }
        bvec2 _508 = bvec2(_507);
        highp vec2 _509 = vec2(_508.x ? _395.x : _503.x, _508.y ? _395.y : _503.y);
        highp float _512 = max(0.0, -(_507 ? _394 : _483));
        highp float _513 = -_512;
        highp float _516 = exp(_513 / uData[1].z);
        highp float _522 = _501.y;
        highp float _556;
        highp float _557;
        highp vec2 _558;
        if (_129)
        {
            highp float _530 = max(min(uData[5].y * mix(_154, _441, _463), uData[6].w), 1.0);
            highp float _533 = clamp(1.0 - (_512 / _530), 0.0, 1.0);
            highp float _538 = (((uData[5].z * _530) * _522) * _533) * _533;
            _556 = _533;
            _557 = _538;
            _558 = clamp(((vTextureCoord - (_509 * _538)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _556 = 0.0;
            _557 = 0.0;
            _558 = clamp(((vTextureCoord + (_509 * ((uData[2].x * _522) * _516))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _562 = textureLod(uSampler, _558, 0.0);
        bool _564 = uData[4].w > 0.5;
        highp vec4 _572;
        if (_564)
        {
            _572 = textureLod(uTex1, _558, 0.0);
        }
        else
        {
            _572 = _562;
        }
        bool _577;
        if (_129)
        {
            _577 = uData[6].y > 0.0;
        }
        else
        {
            _577 = false;
        }
        bool _581;
        if (_577)
        {
            _581 = _557 > 0.5;
        }
        else
        {
            _581 = false;
        }
        highp vec4 _642;
        highp vec4 _643;
        if (_581)
        {
            highp vec2 _589 = (_509 * ((_557 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _591 = clamp(_558 + _589, vec2(0.0), vec2(1.0));
            highp vec2 _593 = clamp(_558 - _589, vec2(0.0), vec2(1.0));
            highp vec4 _597 = textureLod(uSampler, _591, 0.0);
            highp float _602 = _562.w;
            highp float _603 = (_597.x / max(_597.w, 9.9999997473787516355514526367188e-05)) * _602;
            highp vec4 _604 = _562;
            _604.x = _603;
            highp vec4 _608 = textureLod(uSampler, _593, 0.0);
            highp float _613 = (_608.z / max(_608.w, 9.9999997473787516355514526367188e-05)) * _602;
            _604.z = _613;
            highp vec4 _641;
            if (_564)
            {
                highp vec4 _621 = textureLod(uTex1, _591, 0.0);
                highp vec4 _628 = _572;
                _628.x = (_621.x / max(_621.w, 9.9999997473787516355514526367188e-05)) * _572.w;
                highp vec4 _632 = textureLod(uTex1, _593, 0.0);
                _628.z = (_632.z / max(_632.w, 9.9999997473787516355514526367188e-05)) * _572.w;
                _641 = _628;
            }
            else
            {
                highp vec4 _639 = _572;
                _639.x = _603;
                _639.z = _613;
                _641 = _639;
            }
            _642 = _641;
            _643 = _604;
        }
        else
        {
            _642 = _572;
            _643 = _562;
        }
        bool _645 = uData[4].x > 1.5;
        highp float _659;
        if (_645)
        {
            _659 = uData[3].w;
        }
        else
        {
            highp float _658;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _658 = 1.0;
            }
            else
            {
                _658 = _643.w;
            }
            _659 = _658;
        }
        highp vec4 _668 = vec4(_643.xyz / vec3(max(_643.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _677 = vec4(_642.xyz / vec3(max(_642.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _684;
        if (_645)
        {
            _684 = 1.0;
        }
        else
        {
            _684 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _688;
        if (_129)
        {
            _688 = !_645;
        }
        else
        {
            _688 = false;
        }
        highp float _697;
        if (_688)
        {
            _697 = _684 * (1.0 - ((_556 * _556) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _684))));
        }
        else
        {
            _697 = _684;
        }
        highp float _700 = 1.0 - _697;
        highp float _708;
        if (_129)
        {
            _708 = _556;
        }
        else
        {
            _708 = _516 * _516;
        }
        highp float _711 = clamp(((uData[2].y * _522) * _708) * _700, 0.0, 1.0);
        highp vec4 _717 = ((_677 * _711) + ((mix(_677, _668, vec4(clamp(_501.x, 0.0, 1.0))) * _700) * (1.0 - _711))) + (uData[3] * _697);
        highp vec4 _760;
        if (_645)
        {
            _760 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _733 = _717 + (_668 * (1.0 - _717.w));
            highp vec4 _759;
            if (uData[7].w < 1.0)
            {
                highp vec3 _738 = _733.xyz;
                highp float _739 = dot(_738, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _740 = 0.60000002384185791015625 * uData[7].w;
                highp float _742 = max(uData[7].w - _740, 9.9999997473787516355514526367188e-05);
                highp float _754;
                if (_739 <= _740)
                {
                    _754 = _739;
                }
                else
                {
                    _754 = _740 + (_742 * (1.0 - exp((-(_739 - _740)) / _742)));
                }
                highp vec3 _757 = _738 * (_754 / max(_739, 9.9999997473787516355514526367188e-05));
                _759 = vec4(_757.x, _757.y, _757.z, _733.w);
            }
            else
            {
                _759 = _733;
            }
            _760 = _759;
        }
        bvec2 _763 = bvec2(uData[6].x > 1.5);
        highp float _766 = dot(_509, vec2(_763.x ? vec2(0.707106769084930419921875, -0.707106769084930419921875).x : vec2(-0.707106769084930419921875).x, _763.y ? vec2(0.707106769084930419921875, -0.707106769084930419921875).y : vec2(-0.707106769084930419921875).y));
        highp float _767 = max(_766, 0.0);
        highp float _769 = max(-_766, 0.0);
        highp float _772 = abs(_766);
        bool _776;
        if (_129)
        {
            _776 = uData[6].z > 0.0;
        }
        else
        {
            _776 = false;
        }
        highp float _796;
        if (_776)
        {
            _796 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _772))) * exp((-max(0.0, -_487)) / (uData[2].z * 2.5));
        }
        else
        {
            _796 = uData[8].x * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_487));
        }
        highp float _806;
        if (_129)
        {
            _806 = max((uData[5].w * _556) * _556, _796) * min(_522, 1.0);
        }
        else
        {
            _806 = 0.0;
        }
        highp float _809 = _659 * (1.0 - _806);
        highp vec4 _815 = vec4(_760.xyz * _809, _809 + _806);
        highp float _833;
        if (_129)
        {
            highp float _824;
            if (_776)
            {
                _824 = uData[6].z * smoothstep(0.75, 1.0, _772);
            }
            else
            {
                _824 = 0.25;
            }
            _833 = _824;
        }
        else
        {
            _833 = (0.449999988079071044921875 * ((_767 * sqrt(_767)) + ((0.75 * _769) * sqrt(_769)))) + 0.0599999986588954925537109375;
        }
        highp float _860;
        if (_776)
        {
            _860 = exp((-max(0.0, -_487)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _859;
            if (_129)
            {
                highp float _847 = -_487;
                _859 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _847) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _847));
            }
            else
            {
                _859 = exp((-max(0.0, -_487)) / uData[2].z);
            }
            _860 = _859;
        }
        highp float _867;
        if (_129)
        {
            _867 = 0.0;
        }
        else
        {
            _867 = (0.039999999105930328369140625 * exp(_513 / uData[1].w)) * _767;
        }
        highp vec2 _870 = mix(_440, _439, vec2(_463));
        highp float _874 = _870.y;
        highp float _880 = clamp((vTextureCoord.y - (_870.x - _874)) / max(2.0 * _874, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _898;
        if (uData[4].z > 0.5)
        {
            _898 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _880)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _880))));
        }
        else
        {
            _898 = 0.0;
        }
        highp vec3 _908 = _815.xyz + vec3(clamp((_898 + _501.z) + ((_522 * uData[2].w) * ((_860 * _833) + _867)), 0.0, 1.0));
        highp vec4 _910 = clamp(vec4(_908.x, _908.y, _908.z, _815.w), vec4(0.0), vec4(1.0));
        highp float _917 = max(_910.w, max(_910.x, max(_910.y, _910.z)));
        highp vec4 _918 = _910;
        _918.w = _917;
        highp vec3 _929 = _918.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _917);
        _933 = clamp(vec4(_929.x, _929.y, _929.z, _918.w), vec4(0.0), vec4(1.0)) * _490;
        break;
    } while(false);
    out_var_SV_Target0 = _933;
}

