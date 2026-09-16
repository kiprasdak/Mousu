// Compiled once per Metal device and shared by every Try area.
enum TryCanvasShaders {
    static let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Frame {
            float4 viewport, scroll, accent, appearance, power, grid, dynamics;
        };
        struct Wave { float4 geometry, timing; };
        struct Raster { float4 position [[position]]; float2 uv; };
        constant float2 corners[6] = {float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
        float4 clip(float2 p, float2 size) { return float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1); }
        vertex Raster fullscreen(uint id [[vertex_id]]) {
            Raster out; out.uv=corners[id]; out.position=clip(out.uv,float2(1)); return out;
        }
        struct DotRaster {
            float4 position [[position]]; float2 local; float radius; float aa; float4 color;
        };
        float glow(float distance) { return pow(max(0.0f,1-distance/25),1.4f); }
        float edgeIntensity(float2 p,float2 size,float exponent,float4 weights) {
            float2 v=clamp(p/size,0.0f,1.0f);
            float4 ramp=(0.001f+0.999f*pow(float4(1-v.x,v.x,1-v.y,v.y),exponent))
                * (0.995f+0.005f*float4(v.y,v.y,v.x,v.x));
            return dot(weights,ramp);
        }
        vertex DotRaster dots(uint vertexIndex [[vertex_id]], uint instance [[instance_id]],
            constant Frame &f [[buffer(0)]], device const float *path [[buffer(1)]],
            constant float4 *fields [[buffer(2)]], constant Wave *waves [[buffer(3)]]) {
            uint col=instance%uint(f.grid.x), row=instance/uint(f.grid.x);
            float spacing=16*f.grid.z;
            float2 center=(float2(col,row)-1)*spacing+f.scroll.xy+1;
            long worldX=long(f.grid.w)+long(col)*long(f.grid.z);
            long worldY=long(f.dynamics.x)+long(row)*long(f.grid.z);
            ulong seed=as_type<ulong>(worldX)*0x9E3779B97F4A7C15UL;
            seed^=as_type<ulong>(worldY)*0xBF58476D1CE4E5B9UL;
            seed=(seed^(seed>>30))*0xBF58476D1CE4E5B9UL;
            seed=(seed^(seed>>27))*0x94D049BB133111EBUL; seed^=seed>>31;
            float brightness=.92f+float(seed&255)/255*.16f;
            float variation=.94f+float((seed>>8)&255)/255*.12f;
            uint speed=uint((seed>>16)%5);
            float sparse=(seed>>24)%48==0 ? .7f+float((seed>>32)&255)/255*.3f : 0;
            float4 distances=float4(center.x,f.viewport.x-center.x,center.y,f.viewport.y-center.y);
            float4 extent=float4(f.viewport.x,f.viewport.x,f.viewport.y,f.viewport.y);
            float4 progress=clamp(distances/(extent*.5f),0.0f,1.0f);
            float4 positions=progress*progress*(3-2*progress)*8;
            float4 weights;
            for(uint edge=0;edge<4;edge++) {
                uint lo=uint(positions[edge]), hi=min(lo+1,8u);
                weights[edge]=mix(fields[speed*9+lo][edge],fields[speed*9+hi][edge],fract(positions[edge]));
            }
            float pulse=edgeIntensity(center,f.viewport.xy,2.2f,weights);
            float scalePulse=edgeIntensity(center,f.viewport.xy,3.8f,weights);
            float click=0;
            for(uint i=0;i<uint(f.dynamics.z);i++) {
                Wave w=waves[i]; float distance=length(center-w.geometry.xy);
                float radius=f.scroll.w>0 ? 0 : 240*w.timing.x;
                float reflected=1;
                if(w.geometry.z>=0) {
                    float axis=w.geometry.z>0 ? abs(center.x-w.geometry.x) : abs(center.y-w.geometry.y);
                    float before=distance*(axis>0 ? min(1.0f,w.geometry.w/axis) : 0);
                    float since=w.timing.x-before/240;
                    if(since<0) continue;
                    radius=before+120*since;
                    float t=clamp(since/.35f,0.0f,1.0f); reflected=1-t*t*(3-2*t);
                }
                click=max(click,glow(abs(distance-radius))*w.timing.y*reflected);
            }
            float accent=f.dynamics.y*sparse;
            float emphasis=min(1.0f,max(max(pulse*brightness+accent*.36f,path[instance]),click));
            float growth=min(13.0f,3*scalePulse+8*scalePulse*scalePulse*scalePulse+2*accent);
            float diameter=2+(f.scroll.w>0 ? 0 : growth*variation);
            float3 highlight=float3(f.appearance.x>0 ? 1 : .12f);
            float3 color=mix(f.accent.rgb,highlight,emphasis*.75f);
            float alpha=min(1.0f,.2f*(.35f+.65f*center.x/f.viewport.x)+.8f*emphasis);
            DotRaster out; out.radius=diameter*.5f;
            out.aa=max(f.viewport.x/f.viewport.z,f.viewport.y/f.viewport.w)*.65f;
            out.local=(corners[vertexIndex]*2-1)*(out.radius+out.aa);
            out.position=clip(center+out.local,f.viewport.xy); out.color=float4(color,alpha); return out;
        }
        fragment float4 dotPixel(DotRaster in [[stage_in]]) {
            float alpha=in.color.a*(1-smoothstep(in.radius-in.aa,in.radius+in.aa,length(in.local)));
            return float4(in.color.rgb*alpha,alpha);
        }
        vertex Raster caption(uint id [[vertex_id]],constant Frame &f [[buffer(0)]],constant float4 &rect [[buffer(1)]]) {
            Raster out; out.uv=corners[id]; out.position=clip(rect.xy+out.uv*rect.zw,f.viewport.xy); return out;
        }
        fragment float4 captionPixel(Raster in [[stage_in]],texture2d<float> image [[texture(0)]],
            constant float &opacity [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_zero);
            return image.sample(s,in.uv)*opacity;
        }
        float roundedDistance(float2 p,float2 size,float radius) {
            float2 q=abs(p-size*.5f)-(size*.5f-radius);
            return length(max(q,0.0f))+min(max(q.x,q.y),0.0f)-radius;
        }
        float3 sourceAt(texture2d<float> scene,float2 p,constant Frame &f) {
            constexpr sampler s(filter::linear,address::clamp_to_edge);
            float3 floorColor=float3(f.appearance.x>0 ? .055f : .94f);
            float2 q=(p-f.viewport.xy*.5f)/max(f.power.xy,float2(.0001f))+f.viewport.xy*.5f;
            if(any(q<0)||any(q>=f.viewport.xy)) return floorColor;
            return mix(floorColor,scene.sample(s,q/f.viewport.xy).rgb,f.power.z);
        }
        fragment float4 screen(Raster in [[stage_in]],constant Frame &f [[buffer(0)]],texture2d<float> scene [[texture(0)]]) {
            constexpr sampler linear(filter::linear,address::clamp_to_edge);
            float2 size=f.viewport.xy, p=in.uv*size;
            float aa=max(size.x/f.viewport.z,size.y/f.viewport.w);
            float clipAlpha=1-smoothstep(-aa,0.0f,roundedDistance(p,size,16));
            if(f.scroll.z<.5f) {
                float4 c=scene.sample(linear,in.uv);
                float reveal=f.appearance.w;
                return float4(c.rgb*reveal,(c.a*reveal+1-reveal))*clipAlpha;
            }
            // Curved inverse projection matches pointer input. Scanlines remain in logical pixels.
            float2 cell=floor(p)+.5f, n=cell/size*2-1;
            float2 mapped=(n*(1+.045f*n.yx*n.yx+.012f*n*n)+1)*size*.5f;
            if(any(mapped<0)||any(mapped>=size)) return float4(float3(2.0f/255)*clipAlpha,clipAlpha);
            float t=f.power.w, y=cell.y/size.y;
            bool animated=f.scroll.w<.5f;
            float glitch=animated ? max(0.0f,1-abs(fmod(t,11.7f)-8.4f)/.18f) : 0;
            float driftBand=max(0.0f,1-abs(y-(.25f+.5f*sin(t*.7f)))/.045f);
            float shift=animated ? sin(t*1.8f+y*7)*.22f+glitch*driftBand*3 : 0;
            float sweep=fmod(t*.09f,1.2f)-.1f;
            float gain=animated ? 1+.008f*sin(t*7.3f)-max(0.0f,1-abs(y-sweep)/.06f)*.035f-glitch*.025f : 1;
            float fringe=.65f+.65f*dot(n,n);
            float3 color;
            color.r=sourceAt(scene,mapped+float2(shift-fringe,0),f).r;
            color.g=sourceAt(scene,mapped+float2(shift,0),f).g;
            color.b=sourceAt(scene,mapped+float2(shift+fringe,0),f).b;
            float3 halo=(sourceAt(scene,mapped+float2(-1,0),f)+sourceAt(scene,mapped+float2(1,0),f)
                +sourceAt(scene,mapped+float2(0,-1),f)+sourceAt(scene,mapped+float2(0,1),f))*.25f;
            float3 wide=(sourceAt(scene,mapped+float2(-3,0),f)+sourceAt(scene,mapped+float2(3,0),f))*.5f;
            float floorValue=f.appearance.x>0 ? 14.0f/255 : 240.0f/255;
            color+=max(float3(0),color-floorValue)*.48f+max(float3(0),halo-floorValue)*.30f+max(float3(0),wide-floorValue)*.12f;
            color=max(float3(0),color-floorValue*(1-f.power.z));
            float strength=max(0.0f,1-f.power.y/.12f)*f.power.z;
            float dy=cell.y-size.y*.5f;
            float trace=exp(-dy*dy/2.5f)+.18f*exp(-dy*dy/45);
            float radius=max(1.5f,size.x*f.power.x*.46f);
            color+=strength*trace*exp(-pow(abs(cell.x-size.x*.5f)/radius,6.0f))*(210.0f/255);
            float edge=max(abs(mapped.x/size.x*2-1),abs(mapped.y/size.y*2-1));
            float rim=clamp((1.015f-edge)/.045f,0.0f,1.0f);
            uint row=uint(cell.y), col=uint(cell.x);
            float scan=row%4==3 ? .60f : (row%4==2 ? .88f : 1.04f);
            float shade=rim*(1-.16f*dot(n,n))*scan*(1+.025f*sin(cell.y*.13f)+.012f*sin(cell.y*.71f));
            ulong seed=ulong(col)*374761393UL ^ ulong(row)*668265263UL;
            float grain=(float((seed^(seed>>13))%101)/100-.5f)*1.4f/255;
            float reflection=max(0.0f,1-pow((n.x+.45f)/1.2f,2.0f)-pow((n.y+.8f)/.9f,2.0f))*1.8f/255;
            float3 mask=float3(col%3==0 ? 1 : .68f,col%3==1 ? 1 : .68f,col%3==2 ? 1 : .68f);
            color=clamp((color+grain+reflection)*shade*mask*gain,0.0f,1.0f);
            // The stationary glass surround is analytic, avoiding repeated path rasterization.
            for(int inset=24;inset>=4;inset--) {
                float distance=abs(roundedDistance(p-float(inset)*.5f,size-float(inset),20));
                color*=1-.025f*(1-smoothstep(float(inset)*.5f-aa,float(inset)*.5f+aa,distance));
            }
            float lip=1-smoothstep(3-aa,3+aa,abs(roundedDistance(p-3,size-6,16)));
            color=mix(color,float3(.035f),lip);
            float glint=1-smoothstep(.5f-aa,.5f+aa,abs(roundedDistance(p-.5f,size-1,16)));
            color=mix(color,float3(1),glint*.1f);
            return float4(color*clipAlpha,clipAlpha);
        }
        """#
}
