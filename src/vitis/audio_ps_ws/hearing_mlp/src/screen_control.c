#include "screen_control.h"
#include <string.h>
int screen_command_feed(uint8_t byte) {
    static char line[24];
    static unsigned used;
    static int discard;
    int result=-1;
    if(byte=='\r')return -1;
    if(byte=='\n') {
        if(!discard) {
            line[used]=0;
            if(strcmp(line,"VIEW:DIR")==0)result=0;
            else if(strcmp(line,"VIEW:ICON")==0)result=1;
            else if(strcmp(line,"VIEW:GET")==0)result=2;
            else if(strcmp(line,"GAIN:1")==0)result=10;
            else if(strcmp(line,"GAIN:2")==0)result=11;
            else if(strcmp(line,"GAIN:4")==0)result=12;
            else if(strcmp(line,"GAIN:8")==0)result=13;
            else if(strcmp(line,"WAVE:OFF")==0)result=20;
            else if(strcmp(line,"WAVE:ON")==0)result=21;
            else if(strcmp(line,"REC:START")==0)result=30;
        }
        used=0;discard=0;return result;
    }
    if(byte<32 || byte>126 || used>=sizeof(line)-1) {discard=1;return -1;}
    if(!discard)line[used++]=(char)byte;
    return -1;
}
