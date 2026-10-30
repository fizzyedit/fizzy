#version 300 es
precision highp float;
precision highp int;

uniform highp vec4 uData[59];
uniform highp sampler2D uSampler;
uniform highp sampler2D uTex1;

in highp vec4 vColor;
in highp vec2 vTextureCoord;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _1708;
    do
    {
        int _110 = int((vColor.y * 255.0) + 0.5);
        int _115 = int((vColor.z * 255.0) + 0.5);
        bool _139 = uData[5].y > 0.0;
        highp vec2 _141;
        highp float _144;
        highp vec2 _146;
        highp vec2 _148;
        highp vec4 _150;
        highp vec2 _152;
        highp float _154;
        highp float _156;
        highp vec2 _158;
        highp vec2 _160;
        highp vec4 _162;
        highp float _164;
        highp float _166;
        highp float _168;
        _141 = vec2(0.0, 1.0);
        _144 = 1000000000.0;
        _146 = vec2(0.0);
        _148 = vec2(0.0);
        _150 = vec4(0.0);
        _152 = vec2(0.0);
        _154 = 1000000000.0;
        _156 = 1000000000.0;
        _158 = vec2(0.0);
        _160 = vec2(0.0, 1.0);
        _162 = vec4(0.0);
        _164 = 1000000000.0;
        _166 = 1000000000.0;
        _168 = 1000000000.0;
        highp vec2 _153;
        highp float _157;
        highp vec2 _159;
        highp vec4 _163;
        highp float _167;
        highp float _169;
        highp vec2 _142;
        highp float _145;
        highp vec2 _147;
        highp vec2 _149;
        highp vec4 _151;
        highp float _155;
        highp vec2 _161;
        highp float _165;
        int _170 = _110;
        for (;;)
        {
            bool _179;
            if (_170 < (_110 + _115))
            {
                _179 = _170 < 16;
            }
            else
            {
                _179 = false;
            }
            if (_179)
            {
                int _181 = 3 * _170;
                int _188 = _181 + 13;
                bool _196;
                if (uData[_188 * 1 + 0].w >= (-0.5))
                {
                    _196 = uData[_188 * 1 + 0].w > 3.5;
                }
                else
                {
                    _196 = true;
                }
                highp vec4 _206;
                highp vec4 _207;
                highp vec4 _208;
                if (_196)
                {
                    highp vec4 _204 = uData[58];
                    _204.z = 0.0;
                    _206 = _204;
                    _207 = uData[56];
                    _208 = uData[57];
                }
                else
                {
                    _206 = uData[_188 * 1 + 0];
                    _207 = uData[(11 + _181) * 1 + 0];
                    _208 = uData[(_181 + 12) * 1 + 0];
                }
                highp float _211 = min(_207.z, _207.w);
                highp vec4 _213 = min(_208, vec4(_211));
                highp vec2 _215 = vTextureCoord - _207.xy;
                highp float _217 = _215.x;
                highp float _238;
                if (_217 > 0.0)
                {
                    highp float _237;
                    if (_215.y > 0.0)
                    {
                        _237 = _213.z;
                    }
                    else
                    {
                        _237 = _213.y;
                    }
                    _238 = _237;
                }
                else
                {
                    highp float _229;
                    if (_215.y > 0.0)
                    {
                        _229 = _213.w;
                    }
                    else
                    {
                        _229 = _213.x;
                    }
                    _238 = _229;
                }
                highp vec2 _242 = (abs(_215) - _207.zw) + vec2(_238);
                highp float _244 = (_217 < 0.0) ? (-1.0) : 1.0;
                highp float _247 = (_215.y < 0.0) ? (-1.0) : 1.0;
                highp float _249 = _242.x;
                bool _255;
                if (_249 > 0.0)
                {
                    _255 = _242.y > 0.0;
                }
                else
                {
                    _255 = false;
                }
                highp vec2 _269;
                if (_255)
                {
                    _269 = normalize(_242) * vec2(_244, _247);
                }
                else
                {
                    highp vec2 _266;
                    if (_249 > _242.y)
                    {
                        _266 = vec2(_244, 0.0);
                    }
                    else
                    {
                        _266 = vec2(0.0, _247);
                    }
                    _269 = _266;
                }
                highp vec2 _497;
                highp float _498;
                if (_196)
                {
                    highp vec4 _287 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
                    int _290 = int(uData[58].z);
                    highp vec2 _292 = vTextureCoord - uData[56].xy;
                    highp float _294 = _292.x;
                    highp float _315;
                    if (_294 > 0.0)
                    {
                        highp float _314;
                        if (_292.y > 0.0)
                        {
                            _314 = _287.z;
                        }
                        else
                        {
                            _314 = _287.y;
                        }
                        _315 = _314;
                    }
                    else
                    {
                        highp float _306;
                        if (_292.y > 0.0)
                        {
                            _306 = _287.w;
                        }
                        else
                        {
                            _306 = _287.x;
                        }
                        _315 = _306;
                    }
                    highp vec2 _319 = (abs(_292) - uData[56].zw) + vec2(_315);
                    highp float _321 = (_294 < 0.0) ? (-1.0) : 1.0;
                    highp float _324 = (_292.y < 0.0) ? (-1.0) : 1.0;
                    highp float _326 = _319.x;
                    bool _332;
                    if (_326 > 0.0)
                    {
                        _332 = _319.y > 0.0;
                    }
                    else
                    {
                        _332 = false;
                    }
                    highp vec2 _346;
                    if (_332)
                    {
                        _346 = normalize(_319) * vec2(_321, _324);
                    }
                    else
                    {
                        highp vec2 _343;
                        if (_326 > _319.y)
                        {
                            _343 = vec2(_321, 0.0);
                        }
                        else
                        {
                            _343 = vec2(0.0, _324);
                        }
                        _346 = _343;
                    }
                    highp vec2 _355;
                    highp float _358;
                    _355 = _346;
                    _358 = (min(max(_326, _319.y), 0.0) + length(max(_319, vec2(0.0)))) - _315;
                    highp vec2 _356;
                    highp float _359;
                    int _360 = 0;
                    for (;;)
                    {
                        bool _368;
                        if (_360 < _290)
                        {
                            _368 = _360 < 4;
                        }
                        else
                        {
                            _368 = false;
                        }
                        if (_368)
                        {
                            int _370 = 14 - _360;
                            int _371 = 3 * _370;
                            int _372 = 11 + _371;
                            int _375 = _371 + 12;
                            if (uData[_375 * 1 + 0].x == 0.0)
                            {
                                _356 = _355;
                                _359 = _358;
                                int _361 = _360 + 1;
                                _355 = _356;
                                _358 = _359;
                                _360 = _361;
                                continue;
                            }
                            highp float _384 = clamp(uData[_375 * 1 + 0].x / uData[_375 * 1 + 0].y, 0.0, 1.0);
                            bool _386 = uData[_372 * 1 + 0].x < 0.5;
                            highp float _394;
                            if (_386)
                            {
                                _394 = vTextureCoord.y;
                            }
                            else
                            {
                                _394 = vTextureCoord.x;
                            }
                            highp float _402;
                            if (_386)
                            {
                                _402 = vTextureCoord.x;
                            }
                            else
                            {
                                _402 = vTextureCoord.y;
                            }
                            highp float _404 = _402 - uData[_372 * 1 + 0].y;
                            highp float _405 = uData[_375 * 1 + 0].x * 0.5;
                            highp float _408 = uData[_372 * 1 + 0].w - uData[_372 * 1 + 0].z;
                            highp float _409 = smoothstep(0.0, 0.60000002384185791015625, _384);
                            highp float _438;
                            highp float _439;
                            if (uData[_375 * 1 + 0].w > 2.5)
                            {
                                highp float _429 = _394 - ((uData[_372 * 1 + 0].z + uData[_372 * 1 + 0].w) * 0.5);
                                _438 = (_429 < 0.0) ? 1.0 : (-1.0);
                                _439 = max(((_408 * 0.5) * (1.0 - _409)) - abs(_429), 0.0);
                            }
                            else
                            {
                                bool _415 = uData[_375 * 1 + 0].w < 1.5;
                                highp float _421;
                                if (_415)
                                {
                                    _421 = _394 - uData[_372 * 1 + 0].z;
                                }
                                else
                                {
                                    _421 = uData[_372 * 1 + 0].w - _394;
                                }
                                _438 = _415 ? 1.0 : (-1.0);
                                _439 = max(_421 - ((_408 - _405) * _409), 0.0);
                            }
                            highp float _441 = length(vec2(_404, _439));
                            highp float _442 = _441 - _405;
                            highp vec2 _457;
                            if (_441 > 0.0)
                            {
                                highp vec2 _451 = vec2(-_404, (-_439) * _438) / vec2(_441);
                                highp vec2 _456;
                                if (uData[_372 * 1 + 0].x > 0.5)
                                {
                                    _456 = _451.yx;
                                }
                                else
                                {
                                    _456 = _451;
                                }
                                _457 = _456;
                            }
                            else
                            {
                                _457 = vec2(0.0);
                            }
                            highp float _459 = uData[_375 * 1 + 0].z * _384;
                            highp vec2 _463 = max(vec2(_459 + _358, _459 - _442), vec2(0.0));
                            highp float _464 = length(_463);
                            bool _469;
                            if (_459 > 0.0)
                            {
                                _469 = _464 > 0.0;
                            }
                            else
                            {
                                _469 = false;
                            }
                            highp vec2 _484;
                            if (_469)
                            {
                                _484 = ((_355 * _463.x) + (_457 * _463.y)) / vec2(_464);
                            }
                            else
                            {
                                bvec2 _475 = bvec2((-_442) > _358);
                                _484 = vec2(_475.x ? _457.x : _355.x, _475.y ? _457.y : _355.y);
                            }
                            highp float _485 = -_442;
                            highp float _496;
                            do
                            {
                                if (_459 == 0.0)
                                {
                                    _496 = max(_358, _485);
                                    break;
                                }
                                _496 = min(-_459, max(_358, _485)) + _464;
                                break;
                            } while(false);
                            _356 = _484;
                            _359 = _496;
                            int _361 = _360 + 1;
                            _355 = _356;
                            _358 = _359;
                            _360 = _361;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _497 = _355;
                    _498 = _358;
                }
                else
                {
                    _497 = _269;
                    _498 = (min(max(_249, _242.y), 0.0) + length(max(_242, vec2(0.0)))) - _238;
                }
                highp vec2 _644;
                if (uData[10].w > 0.0)
                {
                    highp float _507 = (uData[9].x < 0.0) ? (-1.0) : 1.0;
                    highp float _510 = (uData[9].y < 0.0) ? (-1.0) : 1.0;
                    highp float _530;
                    if (_507 < 0.0)
                    {
                        highp float _529;
                        if (_510 < 0.0)
                        {
                            _529 = _213.x;
                        }
                        else
                        {
                            _529 = _213.w;
                        }
                        _530 = _529;
                    }
                    else
                    {
                        highp float _522;
                        if (_510 < 0.0)
                        {
                            _522 = _213.y;
                        }
                        else
                        {
                            _522 = _213.z;
                        }
                        _530 = _522;
                    }
                    highp vec2 _533 = max(_207.zw - vec2(_530), vec2(0.0));
                    highp vec2 _537 = (_207.xy + (vec2(_507, _510) * _533)) + (uData[9].xy * _530);
                    highp vec2 _552;
                    if (abs(uData[9].x) < 0.001000000047497451305389404296875)
                    {
                        highp float _545 = _533.x;
                        highp vec2 _551 = _537;
                        _551.x = clamp(vTextureCoord.x, _207.x - _545, _207.x + _545) + (_530 * uData[9].x);
                        _552 = _551;
                    }
                    else
                    {
                        _552 = _537;
                    }
                    highp vec2 _567;
                    if (abs(uData[9].y) < 0.001000000047497451305389404296875)
                    {
                        highp float _560 = _533.y;
                        highp vec2 _566 = _552;
                        _566.y = clamp(vTextureCoord.y, _207.y - _560, _207.y + _560) + (_530 * uData[9].y);
                        _567 = _566;
                    }
                    else
                    {
                        _567 = _552;
                    }
                    highp float _570 = max(uData[10].w - max(uData[8].w, 1.0), 0.0);
                    highp vec2 _575 = -uData[9].xy;
                    highp float _576 = _575.x;
                    highp float _578 = (_576 < 0.0) ? (-1.0) : 1.0;
                    highp float _579 = _575.y;
                    highp float _581 = (_579 < 0.0) ? (-1.0) : 1.0;
                    highp float _601;
                    if (_578 < 0.0)
                    {
                        highp float _600;
                        if (_581 < 0.0)
                        {
                            _600 = _213.x;
                        }
                        else
                        {
                            _600 = _213.w;
                        }
                        _601 = _600;
                    }
                    else
                    {
                        highp float _593;
                        if (_581 < 0.0)
                        {
                            _593 = _213.y;
                        }
                        else
                        {
                            _593 = _213.z;
                        }
                        _601 = _593;
                    }
                    highp vec2 _604 = max(_207.zw - vec2(_601), vec2(0.0));
                    highp vec2 _608 = (_207.xy + (vec2(_578, _581) * _604)) + (_575 * _601);
                    highp vec2 _623;
                    if (abs(_576) < 0.001000000047497451305389404296875)
                    {
                        highp float _616 = _604.x;
                        highp vec2 _622 = _608;
                        _622.x = clamp(vTextureCoord.x, _207.x - _616, _207.x + _616) + (_601 * _576);
                        _623 = _622;
                    }
                    else
                    {
                        _623 = _608;
                    }
                    highp vec2 _638;
                    if (abs(_579) < 0.001000000047497451305389404296875)
                    {
                        highp float _631 = _604.y;
                        highp vec2 _637 = _623;
                        _637.y = clamp(vTextureCoord.y, _207.y - _631, _207.y + _631) + (_601 * _579);
                        _638 = _637;
                    }
                    else
                    {
                        _638 = _623;
                    }
                    _644 = vec2(1.0 - smoothstep(_570, uData[10].w, length(vTextureCoord - _567)), 1.0 - smoothstep(_570, uData[10].w, length(vTextureCoord - _638)));
                }
                else
                {
                    _644 = vec2(0.0);
                }
                bool _645 = _498 < _166;
                if (_645)
                {
                    _142 = _160;
                    _145 = _168;
                    _147 = _158;
                    _151 = _162;
                    _161 = _207.yw;
                    _165 = _166;
                }
                else
                {
                    bool _649 = _498 < _164;
                    highp vec2 _653;
                    if (_649)
                    {
                        _653 = _207.yw;
                    }
                    else
                    {
                        _653 = _141;
                    }
                    bvec2 _655 = bvec2(_649);
                    bvec4 _657 = bvec4(_649);
                    _142 = _653;
                    _145 = _649 ? _211 : _144;
                    _147 = vec2(_655.x ? _644.x : _146.x, _655.y ? _644.y : _146.y);
                    _151 = vec4(_657.x ? _206.x : _150.x, _657.y ? _206.y : _150.y, _657.z ? _206.z : _150.z, _657.w ? _206.w : _150.w);
                    _161 = _160;
                    _165 = _649 ? _498 : _164;
                }
                bvec2 _661 = bvec2(_645);
                _159 = vec2(_661.x ? _644.x : _158.x, _661.y ? _644.y : _158.y);
                bvec4 _662 = bvec4(_645);
                _163 = vec4(_662.x ? _206.x : _162.x, _662.y ? _206.y : _162.y, _662.z ? _206.z : _162.z, _662.w ? _206.w : _162.w);
                _167 = _645 ? _498 : _166;
                _169 = _645 ? _211 : _168;
                highp vec2 _707;
                highp float _708;
                if (_206.w < 0.5)
                {
                    highp float _673 = (vTextureCoord.x - _207.x) + _207.z;
                    highp float _675 = (_207.x + _207.z) - vTextureCoord.x;
                    highp float _680 = (vTextureCoord.y - _207.y) + _207.w;
                    highp float _682 = (_207.y + _207.w) - vTextureCoord.y;
                    highp float _686 = min(min(_673, _675), min(_680, _682));
                    highp vec4 _691 = exp((vec4(_686) - vec4(_673, _675, _680, _682)) / vec4(uData[1].y));
                    highp float _692 = _691.x;
                    highp float _693 = _691.y;
                    highp float _695 = _691.z;
                    highp float _697 = _691.w;
                    highp float _698 = ((_692 + _693) + _695) + _697;
                    _707 = vec2(_693 - _692, _697 - _695) / vec2(_698);
                    _708 = (uData[1].y * log(_698)) - _686;
                }
                else
                {
                    _707 = _497;
                    _708 = _498;
                }
                highp vec2 _974;
                highp float _975;
                if (_196)
                {
                    highp vec4 _720 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
                    int _723 = int(uData[58].z);
                    highp vec2 _829;
                    highp float _830;
                    if (uData[1].y > 0.0)
                    {
                        highp float _795 = (vTextureCoord.x - uData[56].x) + uData[56].z;
                        highp float _797 = (uData[56].x + uData[56].z) - vTextureCoord.x;
                        highp float _802 = (vTextureCoord.y - uData[56].y) + uData[56].w;
                        highp float _804 = (uData[56].y + uData[56].w) - vTextureCoord.y;
                        highp float _808 = min(min(_795, _797), min(_802, _804));
                        highp vec4 _813 = exp((vec4(_808) - vec4(_795, _797, _802, _804)) / vec4(uData[1].y));
                        highp float _814 = _813.x;
                        highp float _815 = _813.y;
                        highp float _817 = _813.z;
                        highp float _819 = _813.w;
                        highp float _820 = ((_814 + _815) + _817) + _819;
                        _829 = vec2(_815 - _814, _819 - _817) / vec2(_820);
                        _830 = (uData[1].y * log(_820)) - _808;
                    }
                    else
                    {
                        highp vec2 _729 = vTextureCoord - uData[56].xy;
                        highp float _731 = _729.x;
                        highp float _752;
                        if (_731 > 0.0)
                        {
                            highp float _751;
                            if (_729.y > 0.0)
                            {
                                _751 = _720.z;
                            }
                            else
                            {
                                _751 = _720.y;
                            }
                            _752 = _751;
                        }
                        else
                        {
                            highp float _743;
                            if (_729.y > 0.0)
                            {
                                _743 = _720.w;
                            }
                            else
                            {
                                _743 = _720.x;
                            }
                            _752 = _743;
                        }
                        highp vec2 _756 = (abs(_729) - uData[56].zw) + vec2(_752);
                        highp float _758 = (_731 < 0.0) ? (-1.0) : 1.0;
                        highp float _761 = (_729.y < 0.0) ? (-1.0) : 1.0;
                        highp float _763 = _756.x;
                        bool _769;
                        if (_763 > 0.0)
                        {
                            _769 = _756.y > 0.0;
                        }
                        else
                        {
                            _769 = false;
                        }
                        highp vec2 _783;
                        if (_769)
                        {
                            _783 = normalize(_756) * vec2(_758, _761);
                        }
                        else
                        {
                            highp vec2 _780;
                            if (_763 > _756.y)
                            {
                                _780 = vec2(_758, 0.0);
                            }
                            else
                            {
                                _780 = vec2(0.0, _761);
                            }
                            _783 = _780;
                        }
                        _829 = _783;
                        _830 = (min(max(_763, _756.y), 0.0) + length(max(_756, vec2(0.0)))) - _752;
                    }
                    highp vec2 _832;
                    highp float _835;
                    _832 = _829;
                    _835 = _830;
                    highp vec2 _833;
                    highp float _836;
                    int _837 = 0;
                    for (;;)
                    {
                        bool _845;
                        if (_837 < _723)
                        {
                            _845 = _837 < 4;
                        }
                        else
                        {
                            _845 = false;
                        }
                        if (_845)
                        {
                            int _847 = 14 - _837;
                            int _848 = 3 * _847;
                            int _849 = 11 + _848;
                            int _852 = _848 + 12;
                            if (uData[_852 * 1 + 0].x == 0.0)
                            {
                                _833 = _832;
                                _836 = _835;
                                int _838 = _837 + 1;
                                _832 = _833;
                                _835 = _836;
                                _837 = _838;
                                continue;
                            }
                            highp float _861 = clamp(uData[_852 * 1 + 0].x / uData[_852 * 1 + 0].y, 0.0, 1.0);
                            bool _863 = uData[_849 * 1 + 0].x < 0.5;
                            highp float _871;
                            if (_863)
                            {
                                _871 = vTextureCoord.y;
                            }
                            else
                            {
                                _871 = vTextureCoord.x;
                            }
                            highp float _879;
                            if (_863)
                            {
                                _879 = vTextureCoord.x;
                            }
                            else
                            {
                                _879 = vTextureCoord.y;
                            }
                            highp float _881 = _879 - uData[_849 * 1 + 0].y;
                            highp float _882 = uData[_852 * 1 + 0].x * 0.5;
                            highp float _885 = uData[_849 * 1 + 0].w - uData[_849 * 1 + 0].z;
                            highp float _886 = smoothstep(0.0, 0.60000002384185791015625, _861);
                            highp float _915;
                            highp float _916;
                            if (uData[_852 * 1 + 0].w > 2.5)
                            {
                                highp float _906 = _871 - ((uData[_849 * 1 + 0].z + uData[_849 * 1 + 0].w) * 0.5);
                                _915 = (_906 < 0.0) ? 1.0 : (-1.0);
                                _916 = max(((_885 * 0.5) * (1.0 - _886)) - abs(_906), 0.0);
                            }
                            else
                            {
                                bool _892 = uData[_852 * 1 + 0].w < 1.5;
                                highp float _898;
                                if (_892)
                                {
                                    _898 = _871 - uData[_849 * 1 + 0].z;
                                }
                                else
                                {
                                    _898 = uData[_849 * 1 + 0].w - _871;
                                }
                                _915 = _892 ? 1.0 : (-1.0);
                                _916 = max(_898 - ((_885 - _882) * _886), 0.0);
                            }
                            highp float _918 = length(vec2(_881, _916));
                            highp float _919 = _918 - _882;
                            highp vec2 _934;
                            if (_918 > 0.0)
                            {
                                highp vec2 _928 = vec2(-_881, (-_916) * _915) / vec2(_918);
                                highp vec2 _933;
                                if (uData[_849 * 1 + 0].x > 0.5)
                                {
                                    _933 = _928.yx;
                                }
                                else
                                {
                                    _933 = _928;
                                }
                                _934 = _933;
                            }
                            else
                            {
                                _934 = vec2(0.0);
                            }
                            highp float _936 = uData[_852 * 1 + 0].z * _861;
                            highp vec2 _940 = max(vec2(_936 + _835, _936 - _919), vec2(0.0));
                            highp float _941 = length(_940);
                            bool _946;
                            if (_936 > 0.0)
                            {
                                _946 = _941 > 0.0;
                            }
                            else
                            {
                                _946 = false;
                            }
                            highp vec2 _961;
                            if (_946)
                            {
                                _961 = ((_832 * _940.x) + (_934 * _940.y)) / vec2(_941);
                            }
                            else
                            {
                                bvec2 _952 = bvec2((-_919) > _835);
                                _961 = vec2(_952.x ? _934.x : _832.x, _952.y ? _934.y : _832.y);
                            }
                            highp float _962 = -_919;
                            highp float _973;
                            do
                            {
                                if (_936 == 0.0)
                                {
                                    _973 = max(_835, _962);
                                    break;
                                }
                                _973 = min(-_936, max(_835, _962)) + _941;
                                break;
                            } while(false);
                            _833 = _961;
                            _836 = _973;
                            int _838 = _837 + 1;
                            _832 = _833;
                            _835 = _836;
                            _837 = _838;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _974 = _832;
                    _975 = _835;
                }
                else
                {
                    _974 = _707;
                    _975 = _708;
                }
                bool _976 = _975 < _156;
                if (_976)
                {
                    _149 = _152;
                    _155 = _156;
                }
                else
                {
                    bool _980 = _975 < _154;
                    bvec2 _981 = bvec2(_980);
                    _149 = vec2(_981.x ? _974.x : _148.x, _981.y ? _974.y : _148.y);
                    _155 = _980 ? _975 : _154;
                }
                bvec2 _984 = bvec2(_976);
                _153 = vec2(_984.x ? _974.x : _152.x, _984.y ? _974.y : _152.y);
                _157 = _976 ? _975 : _156;
                _141 = _142;
                _144 = _145;
                _146 = _147;
                _148 = _149;
                _150 = _151;
                _152 = _153;
                _154 = _155;
                _156 = _157;
                _158 = _159;
                _160 = _161;
                _162 = _163;
                _164 = _165;
                _166 = _167;
                _168 = _169;
                _170++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _994;
        if (uData[58].w > 2.5)
        {
            _994 = uData[58].w < 3.5;
        }
        else
        {
            _994 = false;
        }
        bool _995 = uData[58].w > 1.5;
        bool _999;
        if (_995)
        {
            _999 = uData[58].w < 3.5;
        }
        else
        {
            _999 = false;
        }
        highp float _1072;
        highp vec2 _1073;
        if (_999)
        {
            highp vec2 _1005 = vTextureCoord - uData[56].xy;
            highp vec4 _1011 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
            highp float _1012 = _1005.x;
            highp float _1033;
            if (_1012 > 0.0)
            {
                highp float _1032;
                if (_1005.y > 0.0)
                {
                    _1032 = _1011.z;
                }
                else
                {
                    _1032 = _1011.y;
                }
                _1033 = _1032;
            }
            else
            {
                highp float _1024;
                if (_1005.y > 0.0)
                {
                    _1024 = _1011.w;
                }
                else
                {
                    _1024 = _1011.x;
                }
                _1033 = _1024;
            }
            highp vec2 _1037 = (abs(_1005) - uData[56].zw) + vec2(_1033);
            highp float _1039 = (_1012 < 0.0) ? (-1.0) : 1.0;
            highp float _1042 = (_1005.y < 0.0) ? (-1.0) : 1.0;
            highp float _1044 = _1037.x;
            bool _1050;
            if (_1044 > 0.0)
            {
                _1050 = _1037.y > 0.0;
            }
            else
            {
                _1050 = false;
            }
            highp vec2 _1064;
            if (_1050)
            {
                _1064 = normalize(_1037) * vec2(_1039, _1042);
            }
            else
            {
                highp vec2 _1061;
                if (_1044 > _1037.y)
                {
                    _1061 = vec2(_1039, 0.0);
                }
                else
                {
                    _1061 = vec2(0.0, _1042);
                }
                _1064 = _1061;
            }
            _1072 = (min(max(_1044, _1037.y), 0.0) + length(max(_1037, vec2(0.0)))) - _1033;
            _1073 = _1064;
        }
        else
        {
            _1072 = -1000000000.0;
            _1073 = vec2(0.0);
        }
        bool _1077;
        if (_995)
        {
            _1077 = uData[58].w < 3.5;
        }
        else
        {
            _1077 = false;
        }
        bool _1081;
        if (_1077)
        {
            _1081 = !_994;
        }
        else
        {
            _1081 = false;
        }
        highp vec2 _1126;
        highp vec2 _1127;
        highp float _1128;
        highp vec2 _1129;
        highp vec2 _1130;
        highp vec2 _1131;
        highp vec2 _1132;
        highp vec4 _1133;
        highp vec4 _1134;
        highp float _1135;
        highp float _1136;
        highp float _1137;
        highp float _1138;
        if (_1081)
        {
            highp float _1084 = 1.0 - _1072;
            bool _1085 = _1084 < _166;
            highp vec2 _1101;
            highp vec2 _1102;
            highp float _1103;
            highp vec2 _1104;
            highp vec4 _1105;
            highp float _1106;
            if (_1085)
            {
                _1101 = _160;
                _1102 = uData[56].yw;
                _1103 = _168;
                _1104 = _158;
                _1105 = _162;
                _1106 = _166;
            }
            else
            {
                bool _1089 = _1084 < _164;
                highp vec2 _1093;
                if (_1089)
                {
                    _1093 = uData[56].yw;
                }
                else
                {
                    _1093 = _141;
                }
                bvec2 _1095 = bvec2(_1089);
                bvec4 _1097 = bvec4(_1089);
                _1101 = _1093;
                _1102 = _160;
                _1103 = _1089 ? _168 : _144;
                _1104 = vec2(_1095.x ? vec2(0.0).x : _146.x, _1095.y ? vec2(0.0).y : _146.y);
                _1105 = vec4(_1097.x ? uData[58].x : _150.x, _1097.y ? uData[58].y : _150.y, _1097.z ? uData[58].z : _150.z, _1097.w ? uData[58].w : _150.w);
                _1106 = _1089 ? _1084 : _164;
            }
            bvec2 _1107 = bvec2(_1085);
            bvec4 _1109 = bvec4(_1085);
            highp vec2 _1112 = -_1073;
            bool _1113 = _1084 < _156;
            highp vec2 _1121;
            highp float _1122;
            if (_1113)
            {
                _1121 = _152;
                _1122 = _156;
            }
            else
            {
                bool _1117 = _1084 < _154;
                bvec2 _1118 = bvec2(_1117);
                _1121 = vec2(_1118.x ? _1112.x : _148.x, _1118.y ? _1112.y : _148.y);
                _1122 = _1117 ? _1084 : _154;
            }
            bvec2 _1123 = bvec2(_1113);
            _1126 = _1101;
            _1127 = _1102;
            _1128 = _1103;
            _1129 = _1104;
            _1130 = vec2(_1107.x ? vec2(0.0).x : _158.x, _1107.y ? vec2(0.0).y : _158.y);
            _1131 = _1121;
            _1132 = vec2(_1123.x ? _1112.x : _152.x, _1123.y ? _1112.y : _152.y);
            _1133 = _1105;
            _1134 = vec4(_1109.x ? uData[58].x : _162.x, _1109.y ? uData[58].y : _162.y, _1109.z ? uData[58].z : _162.z, _1109.w ? uData[58].w : _162.w);
            _1135 = _1122;
            _1136 = _1113 ? _1084 : _156;
            _1137 = _1106;
            _1138 = _1085 ? _1084 : _166;
        }
        else
        {
            _1126 = _141;
            _1127 = _160;
            _1128 = _144;
            _1129 = _146;
            _1130 = _158;
            _1131 = _148;
            _1132 = _152;
            _1133 = _150;
            _1134 = _162;
            _1135 = _154;
            _1136 = _156;
            _1137 = _164;
            _1138 = _166;
        }
        highp float _1140 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _1145 = max(_1140 - abs(_1138 - _1137), 0.0) / _1140;
        highp float _1146 = _1145 * _1145;
        highp float _1147 = _1146 * 0.5;
        highp float _1152;
        if (_1137 < _1138)
        {
            _1152 = 1.0 - _1147;
        }
        else
        {
            _1152 = _1147;
        }
        highp float _1156 = min(_1138, _1137) - ((_1146 * _1140) * 0.25);
        highp float _1161 = max(_1140 - abs(_1136 - _1135), 0.0) / _1140;
        highp float _1162 = _1161 * _1161;
        highp float _1163 = _1162 * 0.5;
        highp float _1168;
        if (_1135 < _1136)
        {
            _1168 = 1.0 - _1163;
        }
        else
        {
            _1168 = _1163;
        }
        highp float _1172 = min(_1136, _1135) - ((_1162 * _1140) * 0.25);
        highp float _1176;
        if (_994)
        {
            _1176 = max(_1156, _1072);
        }
        else
        {
            _1176 = _1156;
        }
        highp float _1179 = clamp(0.5 - max(_1176, _1072), 0.0, 1.0);
        if (_1179 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _1708 = vec4(0.0, 0.0, 0.0, _1179);
            break;
        }
        highp vec4 _1190 = mix(_1134, _1133, vec4(_1152));
        highp vec2 _1192 = mix(_1132, _1131, vec2(_1168));
        bool _1196;
        if (_994)
        {
            _1196 = _1072 > _1172;
        }
        else
        {
            _1196 = false;
        }
        bvec2 _1198 = bvec2(_1196);
        highp vec2 _1199 = vec2(_1198.x ? _1073.x : _1192.x, _1198.y ? _1073.y : _1192.y);
        highp vec2 _1200 = vec2(_1152);
        highp vec2 _1204 = mix(_1130, _1129, _1200) * min(length(_1199), 1.0);
        highp float _1206 = max(0.0, -(_1196 ? _1072 : _1172));
        highp float _1207 = -_1206;
        highp float _1210 = exp(_1207 / uData[1].z);
        highp float _1216 = _1190.y;
        highp float _1250;
        highp float _1251;
        highp vec2 _1252;
        if (_139)
        {
            highp float _1234 = max(min(uData[5].y * mix(_168, _1128, _1152), uData[6].w), 1.0);
            highp float _1237 = clamp(1.0 - (_1206 / _1234), 0.0, 1.0);
            highp float _1242 = (((uData[5].z * _1234) * _1216) * _1237) * _1237;
            _1250 = _1237;
            _1251 = _1242;
            _1252 = clamp(((vTextureCoord - (_1199 * _1242)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _1250 = 0.0;
            _1251 = 0.0;
            _1252 = clamp(((vTextureCoord + (_1199 * ((uData[2].x * _1216) * _1210))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _1256 = textureLod(uSampler, _1252, 0.0);
        bool _1258 = uData[4].w > 0.5;
        highp vec4 _1266;
        if (_1258)
        {
            _1266 = textureLod(uTex1, _1252, 0.0);
        }
        else
        {
            _1266 = _1256;
        }
        bool _1271;
        if (_139)
        {
            _1271 = uData[6].y > 0.0;
        }
        else
        {
            _1271 = false;
        }
        bool _1275;
        if (_1271)
        {
            _1275 = _1251 > 0.5;
        }
        else
        {
            _1275 = false;
        }
        highp vec4 _1336;
        highp vec4 _1337;
        if (_1275)
        {
            highp vec2 _1283 = (_1199 * ((_1251 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _1285 = clamp(_1252 + _1283, vec2(0.0), vec2(1.0));
            highp vec2 _1287 = clamp(_1252 - _1283, vec2(0.0), vec2(1.0));
            highp vec4 _1291 = textureLod(uSampler, _1285, 0.0);
            highp float _1296 = _1256.w;
            highp float _1297 = (_1291.x / max(_1291.w, 9.9999997473787516355514526367188e-05)) * _1296;
            highp vec4 _1298 = _1256;
            _1298.x = _1297;
            highp vec4 _1302 = textureLod(uSampler, _1287, 0.0);
            highp float _1307 = (_1302.z / max(_1302.w, 9.9999997473787516355514526367188e-05)) * _1296;
            _1298.z = _1307;
            highp vec4 _1335;
            if (_1258)
            {
                highp vec4 _1317 = textureLod(uTex1, _1285, 0.0);
                highp vec4 _1324 = _1266;
                _1324.x = (_1317.x / max(_1317.w, 9.9999997473787516355514526367188e-05)) * _1266.w;
                highp vec4 _1328 = textureLod(uTex1, _1287, 0.0);
                _1324.z = (_1328.z / max(_1328.w, 9.9999997473787516355514526367188e-05)) * _1266.w;
                _1335 = _1324;
            }
            else
            {
                highp vec4 _1312 = _1266;
                _1312.x = _1297;
                _1312.z = _1307;
                _1335 = _1312;
            }
            _1336 = _1335;
            _1337 = _1298;
        }
        else
        {
            _1336 = _1266;
            _1337 = _1256;
        }
        bool _1339 = uData[4].x > 1.5;
        highp float _1353;
        if (_1339)
        {
            _1353 = uData[3].w;
        }
        else
        {
            highp float _1351;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _1351 = 1.0;
            }
            else
            {
                _1351 = _1337.w;
            }
            _1353 = _1351;
        }
        highp vec4 _1362 = vec4(_1337.xyz / vec3(max(_1337.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _1371 = vec4(_1336.xyz / vec3(max(_1336.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _1378;
        if (_1339)
        {
            _1378 = 1.0;
        }
        else
        {
            _1378 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _1382;
        if (_139)
        {
            _1382 = !_1339;
        }
        else
        {
            _1382 = false;
        }
        highp float _1391;
        if (_1382)
        {
            _1391 = _1378 * (1.0 - ((_1250 * _1250) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _1378))));
        }
        else
        {
            _1391 = _1378;
        }
        highp float _1394 = 1.0 - _1391;
        highp float _1402;
        if (_139)
        {
            _1402 = _1250;
        }
        else
        {
            _1402 = _1210 * _1210;
        }
        highp float _1405 = clamp(((uData[2].y * _1216) * _1402) * _1394, 0.0, 1.0);
        highp vec4 _1411 = ((_1371 * _1405) + ((mix(_1371, _1362, vec4(clamp(_1190.x, 0.0, 1.0))) * _1394) * (1.0 - _1405))) + (uData[3] * _1391);
        highp vec4 _1454;
        if (_1339)
        {
            _1454 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _1418 = _1411 + (_1362 * (1.0 - _1411.w));
            highp vec4 _1444;
            if (uData[7].w < 1.0)
            {
                highp vec3 _1423 = _1418.xyz;
                highp float _1424 = dot(_1423, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _1425 = 0.60000002384185791015625 * uData[7].w;
                highp float _1427 = max(uData[7].w - _1425, 9.9999997473787516355514526367188e-05);
                highp float _1439;
                if (_1424 <= _1425)
                {
                    _1439 = _1424;
                }
                else
                {
                    _1439 = _1425 + (_1427 * (1.0 - exp((-(_1424 - _1425)) / _1427)));
                }
                highp vec3 _1442 = _1423 * (_1439 / max(_1424, 9.9999997473787516355514526367188e-05));
                _1444 = vec4(_1442.x, _1442.y, _1442.z, _1418.w);
            }
            else
            {
                _1444 = _1418;
            }
            _1454 = _1444;
        }
        highp float _1457 = dot(_1199, uData[9].xy);
        highp float _1458 = max(_1457, 0.0);
        highp float _1460 = max(-_1457, 0.0);
        highp float _1463 = abs(_1457);
        bool _1467;
        if (_139)
        {
            _1467 = uData[6].z > 0.0;
        }
        else
        {
            _1467 = false;
        }
        bool _1469 = uData[10].x > 0.0;
        highp float _1493;
        if (_1469)
        {
            _1493 = 0.0;
        }
        else
        {
            highp float _1492;
            if (_1467)
            {
                _1492 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _1463))) * exp((-max(0.0, -_1176)) / (uData[2].z * 2.5));
            }
            else
            {
                _1492 = uData[8].x * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_1176));
            }
            _1493 = _1492;
        }
        highp float _1503;
        if (_139)
        {
            _1503 = max((uData[5].w * _1250) * _1250, _1493) * min(_1216, 1.0);
        }
        else
        {
            _1503 = 0.0;
        }
        highp float _1506 = _1353 * (1.0 - _1503);
        highp vec4 _1512 = vec4(_1454.xyz * _1506, _1506 + _1503);
        highp float _1534;
        if (_139)
        {
            highp float _1533;
            if (_1467)
            {
                _1533 = uData[6].z * max(smoothstep(0.75, 1.0, _1463), max(_1204.x, _1204.y));
            }
            else
            {
                _1533 = 0.25;
            }
            _1534 = _1533;
        }
        else
        {
            _1534 = (0.449999988079071044921875 * ((_1458 * sqrt(_1458)) + ((0.75 * _1460) * sqrt(_1460)))) + 0.0599999986588954925537109375;
        }
        highp float _1561;
        if (_1467)
        {
            _1561 = exp((-max(0.0, -_1176)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _1555;
            if (_139)
            {
                highp float _1548 = -_1176;
                _1555 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _1548) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _1548));
            }
            else
            {
                _1555 = exp((-max(0.0, -_1176)) / uData[2].z);
            }
            _1561 = _1555;
        }
        highp float _1573;
        if (_1469)
        {
            _1573 = 0.0;
        }
        else
        {
            highp float _1571;
            if (_139)
            {
                _1571 = 0.0;
            }
            else
            {
                _1571 = (0.039999999105930328369140625 * exp(_1207 / uData[1].w)) * _1458;
            }
            _1573 = (_1561 * _1534) + _1571;
        }
        highp vec2 _1574 = mix(_1127, _1126, _1200);
        highp float _1578 = _1574.y;
        highp float _1584 = clamp((vTextureCoord.y - (_1574.x - _1578)) / max(2.0 * _1578, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _1602;
        if (uData[4].z > 0.5)
        {
            _1602 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _1584)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _1584))));
        }
        else
        {
            _1602 = 0.0;
        }
        highp vec3 _1612 = _1512.xyz + vec3(clamp((_1602 + _1190.z) + ((_1216 * uData[2].w) * _1573), 0.0, 1.0));
        highp vec4 _1684;
        if (_1469)
        {
            highp vec2 _1622;
            if (dot(_1199, _1199) > 9.9999999392252902907785028219223e-09)
            {
                _1622 = normalize(_1199);
            }
            else
            {
                _1622 = vec2(0.0);
            }
            highp float _1623 = dot(_1622, uData[9].xy);
            highp float _1625 = mix(8.0, 1.0, uData[9].z);
            highp float _1633 = pow(max(_1623, 0.0), _1625) + (uData[9].w * pow(max(-_1623, 0.0), _1625));
            highp float _1634 = min(_1216, 1.0);
            highp float _1641 = -_1176;
            highp float _1643 = smoothstep(-0.5, 0.5, _1641);
            highp float _1645 = -max(0.0, _1641);
            highp vec3 _1682 = (_1612.xyz * (1.0 - (((uData[10].z * (1.0 - abs(_1623))) * (_1643 * exp(_1645 / max(uData[2].z * 2.5, 0.001000000047497451305389404296875)))) * _1634))) + vec3(_1634 * (((uData[10].x * max(_1633, max(_1204.x, uData[9].w * _1204.y))) * (_1643 * exp(_1645 / max(uData[8].y, 0.001000000047497451305389404296875)))) + ((uData[10].y * _1633) * (smoothstep(uData[8].y - 0.5, uData[8].y + 0.5, _1641) * exp((-max(0.0, _1641 - uData[8].y)) / max(uData[8].z, 0.001000000047497451305389404296875))))));
            _1684 = vec4(_1682.x, _1682.y, _1682.z, _1512.w);
        }
        else
        {
            _1684 = vec4(_1612.x, _1612.y, _1612.z, _1512.w);
        }
        highp vec4 _1685 = clamp(_1684, vec4(0.0), vec4(1.0));
        highp float _1692 = max(_1685.w, max(_1685.x, max(_1685.y, _1685.z)));
        highp vec4 _1693 = _1685;
        _1693.w = _1692;
        highp vec3 _1704 = _1693.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _1692);
        _1708 = clamp(vec4(_1704.x, _1704.y, _1704.z, _1693.w), vec4(0.0), vec4(1.0)) * _1179;
        break;
    } while(false);
    out_var_SV_Target0 = _1708;
}

