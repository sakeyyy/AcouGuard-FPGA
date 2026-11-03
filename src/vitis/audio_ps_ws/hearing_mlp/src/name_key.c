/* AX7021 KEY1 = PS MIO11, active low. Never change a peripheral MIO mux here. */
#include "name_key.h"
#include "name_call.h"
#include "xparameters.h"
#include "xgpiops.h"
#include "xil_io.h"
#include "wave_uart.h"
static XGpioPs keys;
static int enabled,last_raw=1,stable=1,long_sent,boot_released;
static uint32_t changed,pressed;
int name_key_init(void)
{
    XGpioPs_Config *cfg;
    uint32_t mux=Xil_In32(0xF800072CU);
    enabled=0;last_raw=stable=1;long_sent=boot_released=0;changed=pressed=0;
    if(mux&0xfeU){wave_uart_printf("Key: MIO11_not_GPIO mux=0x%08x; use_serial_or_fix_PS_MIO\r\n",mux);return -1;}
#ifdef SDT
    cfg=XGpioPs_LookupConfig(XPAR_XGPIOPS_0_BASEADDR);
#else
    cfg=XGpioPs_LookupConfig(XPAR_XGPIOPS_0_DEVICE_ID);
#endif
    if(!cfg || XGpioPs_CfgInitialize(&keys,cfg,cfg->BaseAddr)!=0)return -2;
    XGpioPs_SetDirectionPin(&keys,11,0);XGpioPs_SetOutputEnablePin(&keys,11,0);
    enabled=1;wave_uart_printf("Key: KEY1=MIO11 short=mode long1200ms=enroll release_before_start\r\n");return 0;
}
void name_key_poll(uint32_t ms)
{
    int raw;
    if(!enabled)return;
    raw=(int)XGpioPs_ReadPin(&keys,11);
    if(raw!=last_raw){last_raw=raw;changed=ms;}
    if(!boot_released){if(raw && ms-changed>=30)boot_released=1;else return;}
    if(ms-changed>=30 && raw!=stable) {
        stable=raw;
        if(!stable){pressed=ms;long_sent=0;}
        else if(!long_sent)nc_key(0);
    }
    if(!stable && !long_sent && ms-pressed>=1200){long_sent=1;nc_key(1);}
}
