#include "imgui.h"
#include "imgui_internal.h"
#include <stddef.h>
extern "C" {
__declspec(dllexport) unsigned jlDockSpaceOverViewport() { return ImGui::DockSpaceOverViewport(); }
__declspec(dllexport) unsigned jlDockBuilderAddNode(unsigned id,int flags) { return ImGui::DockBuilderAddNode(id,flags); }
__declspec(dllexport) void jlDockBuilderRemoveNode(unsigned id) { ImGui::DockBuilderRemoveNode(id); }
__declspec(dllexport) void jlDockBuilderSetNodeSize(unsigned id,float x,float y) { ImGui::DockBuilderSetNodeSize(id,ImVec2(x,y)); }
__declspec(dllexport) unsigned jlDockBuilderSplitNode(unsigned id,int dir,float ratio,unsigned* at,unsigned* opposite) { return ImGui::DockBuilderSplitNode(id,(ImGuiDir)dir,ratio,at,opposite); }
__declspec(dllexport) void jlDockBuilderDockWindow(const char* name,unsigned id) { ImGui::DockBuilderDockWindow(name,id); }
__declspec(dllexport) void jlDockBuilderFinish(unsigned id) { ImGui::DockBuilderFinish(id); }
__declspec(dllexport) unsigned jlWindowDockID(const char* name) { auto w=ImGui::FindWindowByName(name); return w?w->DockId:0; }
__declspec(dllexport) void jlUndockWindow(const char* name) { if(auto w=ImGui::FindWindowByName(name)) ImGui::DockContextProcessUndockWindow(ImGui::GetCurrentContext(),w); }
__declspec(dllexport) bool jlDockingLayoutCheck(size_t io,size_t style,size_t viewport,size_t drawdata,size_t mouse,size_t keys,size_t capture,size_t colors) {
 return io==sizeof(ImGuiIO) && style==sizeof(ImGuiStyle) && viewport==sizeof(ImGuiViewport) && drawdata==sizeof(ImDrawData)
 && mouse==offsetof(ImGuiIO,MousePos) && keys==offsetof(ImGuiIO,KeysData) && capture==offsetof(ImGuiIO,WantCaptureMouse) && colors==offsetof(ImGuiStyle,Colors);
}
}
