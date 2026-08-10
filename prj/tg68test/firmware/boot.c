#include <stdio.h>
#include "uart.h"
#include "hw/spi.h"
#include "minfat.h"

#define SYSBASE 0x01000200
#define HW_SYS(x) *(volatile unsigned short *)(SYSBASE+x)

#define HW_SYS_ROMCTRL 0
#define HW_SYS_ROMCTRL_BOOTROM 1
#define HW_SYS_ROMCTRL_SOFTKICK 2


void BootSoftKick() {
	HW_SYS(HW_SYS_ROMCTRL) = HW_SYS_ROMCTRL_SOFTKICK;	/* Unmap Boot ROM, map softkick and reset */
}

void BootStock() {
	HW_SYS(HW_SYS_ROMCTRL) = 0;	/* Unmap Boot ROM and reset */
}

#define MAXMEMBIT 25

#define ADDRCHECKWORD 0x55aa44bb
#define BYTECHECKWORD 0x33aa44bb
#define ADDRCHECKWORD2 0xf0e1d2c3

void _INIT_1_MemCheck(void)
{
	volatile int *freebase=0x04000000;
	volatile char *charbase=0x04000000;
	char *rambase;
	char *ramtop;
	int i;
	int a1;
	unsigned int aliases=0;
	int banksize;
	unsigned int size=1<<(MAXMEMBIT-19);
	
	// Sanity check
	freebase[0]=ADDRCHECKWORD;
	freebase[1]=ADDRCHECKWORD2;
	charbase[0]=0x33;
	
	if(freebase[0] != BYTECHECKWORD)
		printf("At 0 Expected %x, got %x\n",BYTECHECKWORD,freebase[0]);
	if(freebase[1] != ADDRCHECKWORD2)
		printf("At 4 Expected %x, got %x\n",ADDRCHECKWORD2,freebase[1]);

	// Seed the RAM;
	freebase[0]=ADDRCHECKWORD;
	a1=1;
	for(i=1;i<MAXMEMBIT;++i)
	{
		freebase[a1]=ADDRCHECKWORD;
		a1<<=1;
	}	

	//	If we have a cache we need to flush it here.

	// Now check for aliases
	freebase[0]=ADDRCHECKWORD2;
	a1=1;
	for(i=1;i<MAXMEMBIT;++i)
	{
		if(freebase[a1]==ADDRCHECKWORD2)
			aliases|=a1;
		a1<<=1;
	}
	printf("Aliases: %x\n",aliases);
	aliases<<=2;

	while(aliases)
	{
		aliases=(aliases<<1)&((1<<MAXMEMBIT)-1);	// Test currently supports up to 64m longwords = 256 megabytes.
		size>>=1;
	}
	printf("RAM size (assuming no address faults) is 0x%x megabytes\n",size);
}


int LoadROM(const char *fn) {
	int result=0;
	unsigned char *romaddr=(unsigned char *)0x05f80000;
	if(FilesystemPresent())
		result=LoadFileAbs(fn,romaddr);
	else
		printf("No filesystem present\n");
	return(result);
}

volatile unsigned char *ciaapra = (volatile unsigned char *)0xbfe001;

int main(int argc,char **argv)
{
	DIRENTRY *dir=0;
	int i;

//	if(LoadROM("DIAGROM ROM")) {
	if(LoadROM("KICK    ROM")) {
		BootSoftKick();
	}
	else {
		printf("ROM loading failed\n");
		BootStock();
	}

	while(1) {
		int c=getchar()&(~32);
		if(c) {
			printf("Got character: %d\n",c);
			switch(c) {
				case 'D' :
					printf("Scanning directory\n");
					dir=0;
					while((dir=NextDirEntry(dir==0,0,0)))
					{
						if (dir->Name[0] != SLOT_EMPTY && dir->Name[0] != SLOT_DELETED) // valid entry??
						{
							printf("%s (%s)\n",dir->Name,longfilename);
						}
					}
					break;

				case 'S' :
					printf("SD card size is %d\n",sd_get_size());
					break;

				default:
					putchar(c);
					break;
			}
		}
	}
	return(0);
}

