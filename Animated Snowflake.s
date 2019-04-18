#include <stdlib.h>
#include <stdio.h>
#include <time.h>
    
#define snowflake_pixel_size 15
    
/* This files provides address values that exist in the system */

#define BOARD                 "DE1-SoC"

/* Memory */
#define DDR_BASE              0x00000000
#define DDR_END               0x3FFFFFFF
#define A9_ONCHIP_BASE        0xFFFF0000
#define A9_ONCHIP_END         0xFFFFFFFF
#define SDRAM_BASE            0xC0000000
#define SDRAM_END             0xC3FFFFFF
#define FPGA_ONCHIP_BASE      0xC8000000
#define FPGA_ONCHIP_END       0xC803FFFF
#define FPGA_CHAR_BASE        0xC9000000
#define FPGA_CHAR_END         0xC9001FFF

/* Cyclone V FPGA devices */
#define LEDR_BASE             0xFF200000
#define HEX3_HEX0_BASE        0xFF200020
#define HEX5_HEX4_BASE        0xFF200030
#define SW_BASE               0xFF200040
#define KEY_BASE              0xFF200050
#define JP1_BASE              0xFF200060
#define JP2_BASE              0xFF200070
#define PS2_BASE              0xFF200100
#define PS2_DUAL_BASE         0xFF200108
#define JTAG_UART_BASE        0xFF201000
#define JTAG_UART_2_BASE      0xFF201008
#define IrDA_BASE             0xFF201020
#define TIMER_BASE            0xFF202000
#define AV_CONFIG_BASE        0xFF203000
#define PIXEL_BUF_CTRL_BASE   0xFF203020
#define CHAR_BUF_CTRL_BASE    0xFF203030
#define AUDIO_BASE            0xFF203040
#define VIDEO_IN_BASE         0xFF203060
#define ADC_BASE              0xFF204000

/* Cyclone V HPS devices */
#define HPS_GPIO1_BASE        0xFF709000
#define HPS_TIMER0_BASE       0xFFC08000
#define HPS_TIMER1_BASE       0xFFC09000
#define HPS_TIMER2_BASE       0xFFD00000
#define HPS_TIMER3_BASE       0xFFD01000
#define FPGA_BRIDGE           0xFFD0501C

/* ARM A9 MPCORE devices */
#define   PERIPH_BASE         0xFFFEC000    // base address of peripheral devices
#define   MPCORE_PRIV_TIMER   0xFFFEC600    // PERIPH_BASE + 0x0600

/* Interrupt controller (GIC) CPU interface(s) */
#define MPCORE_GIC_CPUIF      0xFFFEC100    // PERIPH_BASE + 0x100
#define ICCICR                0x00          // offset to CPU interface control reg
#define ICCPMR                0x04          // offset to interrupt priority mask reg
#define ICCIAR                0x0C          // offset to interrupt acknowledge reg
#define ICCEOIR               0x10          // offset to end of interrupt reg
/* Interrupt controller (GIC) distributor interface(s) */
#define MPCORE_GIC_DIST       0xFFFED000    // PERIPH_BASE + 0x1000
#define ICDDCR                0x00          // offset to distributor control reg
#define ICDISER               0x100         // offset to interrupt set-enable regs
#define ICDICER               0x180         // offset to interrupt clear-enable regs
#define ICDIPTR               0x800         // offset to interrupt processor targets regs
#define ICDICFR               0xC00         // offset to interrupt configuration regs

typedef struct Snowflake {
    int pixels[snowflake_pixel_size][snowflake_pixel_size];
    int x, y;  // x, y coordinates of top-left
} Snowflake;

volatile int pixel_buffer_start;
volatile Snowflake snowflakes[1023];
volatile int max_num_snowflakes = 10;
volatile int num_snowflakes = 0;
volatile int y_drop = 1;
volatile int y_drop_prev = 1;

void plot_pixel(int x, int y, short int line_color);
void clear_screen();
void wait_for_vsync();

void generate_snowflake();
void draw_snowflakes();
void rotate_snowflake(int index);

//interrupts
void set_A9_IRQ_stack();
void config_GIC();
void config_KEYs();
void enable_A9_interrupts();
void pushbutton_ISR();

//plotting
void plot_pixel(int x, int y, short int line_color);
void draw_line(int x0, int x1, int y0, int y1, short int color);
void clear_screen();
void wait_for_vsync();

int main(void) {
    srand(time(NULL));
    
    volatile int* pixel_ctrl_ptr = (int*) 0xFF203020;

    /* set front pixel buffer to start of FPGA On-chip memory */
    *(pixel_ctrl_ptr + 1) = 0xC8000000; // first store the address in the 
                                        // back buffer
                                        
    /* now, swap the front/back buffers, to set the front buffer location */
    wait_for_vsync();
    
    /* initialize a pointer to the pixel buffer, used by drawing functions */
    pixel_buffer_start = *pixel_ctrl_ptr;
    clear_screen(); // pixel_buffer_start points to the pixel buffer
    
    /* set back pixel buffer to start of SDRAM memory */
    *(pixel_ctrl_ptr + 1) = 0xC0000000;
    pixel_buffer_start = *(pixel_ctrl_ptr + 1); // we draw on the back buffer
    
    set_A9_IRQ_stack();
	config_GIC();
	config_KEYs();
	enable_A9_interrupts();
    
    volatile int * sw = (int *) SW_BASE;
    volatile int * ledr = (int *) LEDR_BASE;
    
    volatile int wait_frames;
    volatile int current_frame = 0;

    while (1) {
        clear_screen();
        
        wait_frames = 240/(max_num_snowflakes*y_drop);
        current_frame = (current_frame + 1) % wait_frames;
        
        if (current_frame == 0)
            generate_snowflake();
        
        draw_snowflakes();
        
        // poll switches
        int check_max_num = *(sw);
        if (check_max_num != max_num_snowflakes) {
            max_num_snowflakes = check_max_num;
            *(ledr) = max_num_snowflakes;
        }
        
        wait_for_vsync(); // swap front and back buffers on VGA vertical sync
        pixel_buffer_start = *(pixel_ctrl_ptr + 1); // new back buffer
    }
}

// Define the IRQ exception handler
void __attribute__((interrupt)) __cs3_isr_irq() {

	// Read the ICCIAR from the processor interface
	int address = MPCORE_GIC_CPUIF + ICCIAR;
	int int_ID = *((int *)address);

	if (int_ID == 73) // check if interrupt is from the KEYs
		pushbutton_ISR();
	else
		while (1); // if unexpected, then stay here

	// Write to the End of Interrupt Register (ICCEOIR)
	address = MPCORE_GIC_CPUIF + ICCEOIR;
	*((int *)address) = int_ID;
	return;
}

// Define the remaining exception handlers
void __attribute__((interrupt)) __cs3_reset() {
	while (1);
}
void __attribute__((interrupt)) __cs3_isr_undef() {
	while (1);
}
void __attribute__((interrupt)) __cs3_isr_swi() {
	while (1);
}
void __attribute__((interrupt)) __cs3_isr_pabort() {
	while (1);
}
void __attribute__((interrupt)) __cs3_isr_dabort() {
	while (1);
}
void __attribute__((interrupt)) __cs3_isr_fiq() {
	while (1);
}

void set_A9_IRQ_stack() {
	int stack, mode;
	stack = A9_ONCHIP_END - 7; // top of A9 onchip memory, aligned to 8 bytes
	/* change processor to IRQ mode with interrupts disabled */
	mode = 0b11010010;
	asm("msr cpsr, %[ps]" : : [ps] "r"(mode));
	/* set banked stack pointer */
	asm("mov sp, %[ps]" : : [ps] "r"(stack));
	/* go back to SVC mode before executing subroutine return! */
	mode = 0b11010011;
	asm("msr cpsr, %[ps]" : : [ps] "r"(mode));
}

void config_GIC() {
	int address; // used to calculate register addresses
	*((int *)0xFFFED848) = 0x00000100;
	*((int *)0xFFFED108) = 0x00000200;

	// Set Interrupt Priority Mask Register (ICCPMR). Enable interrupts of all priorities
	address = MPCORE_GIC_CPUIF + ICCPMR;
	*((int *)address) = 0xFFFF;

	// Set CPU Interface Control Register (ICCICR). Enable signaling of
	// interrupts
	address = MPCORE_GIC_CPUIF + ICCICR;
	*((int *)address) = 1;

	// Configure the Distributor Control Register (ICDDCR) to send pending
	// interrupts to CPUs
	address = MPCORE_GIC_DIST + ICDDCR;
	*((int *)address) = 1;
}

void config_KEYs() {
	volatile int * KEY_ptr = (int *)KEY_BASE; // pushbutton KEY address
	*(KEY_ptr + 2) = 0xF; // enable interrupts for KEY[1]
}

void enable_A9_interrupts() {
	int status = 0b01010011;
	asm("msr cpsr, %[ps]" : : [ps] "r"(status));
}

void pushbutton_ISR() {
	volatile int * KEY_ptr = (int *)KEY_BASE;
	int edge = *(KEY_ptr + 3);
	*(KEY_ptr + 3) = edge;
	if (edge == 1) {
		y_drop *= 2;
    } else if (edge == 2) {
		if (y_drop != 1)
        	y_drop /= 2;
    } else if (edge == 4) {
        if (y_drop == 0) {
			y_drop = y_drop_prev;
		} else {
            y_drop_prev = y_drop;
            y_drop = 0;
        } 
    } else if (edge == 8) {
		clear_screen();
    }
}

void generate_snowflake() {
    if (num_snowflakes >= max_num_snowflakes)
        return;
    
    Snowflake new_snowflake;
    new_snowflake.y = 0;
    new_snowflake.x = rand() % 320;
    
    // generate random snowflake pattern
    {
        for (int x = 0; x < snowflake_pixel_size; x++)
            for (int y = 0; y < snowflake_pixel_size; y++)
                new_snowflake.pixels[y][x] = 0;
        
        // center cross is always filled
        for (int x = 0; x < snowflake_pixel_size; x++) new_snowflake.pixels[snowflake_pixel_size/2][x] = 1;   
        for (int y = 0; y < snowflake_pixel_size; y++) new_snowflake.pixels[y][snowflake_pixel_size/2] = 1;
        
        // right half of top vertical branch
        for (int y = snowflake_pixel_size/2; y >= 0; y--)
            for (int x = snowflake_pixel_size/2; x < snowflake_pixel_size - y; x++)
                if (new_snowflake.pixels[y][x - 1] == 1 || new_snowflake.pixels[y + 1][x] == 1 || new_snowflake.pixels[y + 1][x - 1] == 1)
                    // just have the likelihood be fixed for now
                    if (rand() % 5 >= 3) new_snowflake.pixels[y][x] = 1;
        
        // left half of top vertical branch
        for (int y = snowflake_pixel_size/2; y >= 0; y--)
            for (int x = snowflake_pixel_size/2; x >= y; x--)
                if (new_snowflake.pixels[y][snowflake_pixel_size - 1 - x] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // right half of bottom vertical branch
        for (int y = snowflake_pixel_size/2; y < snowflake_pixel_size; y++)
            for (int x = snowflake_pixel_size/2; x <= y; x++)
                if (new_snowflake.pixels[snowflake_pixel_size - 1 - y][x] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // left half of bottom vertical branch
        for (int y = snowflake_pixel_size/2; y < snowflake_pixel_size; y++)
            for (int x = snowflake_pixel_size/2; x >= snowflake_pixel_size - y - 1; x--)
                if (new_snowflake.pixels[snowflake_pixel_size - 1 - y][x] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // bottom half of right horizontal branch
        for (int x = snowflake_pixel_size/2; x < snowflake_pixel_size; x++)
            for (int y = snowflake_pixel_size/2; y <= x; y++)
                if (new_snowflake.pixels[x][y] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // top half of right horizontal branch
        for (int x = snowflake_pixel_size/2; x < snowflake_pixel_size; x++)
            for (int y = snowflake_pixel_size/2; y >= snowflake_pixel_size - x - 1; y--)
                if (new_snowflake.pixels[x][y] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // bottom half of left horizontal branch
        for (int x = snowflake_pixel_size/2; x >= 0; x--)
            for (int y = snowflake_pixel_size/2; y < snowflake_pixel_size - x; y++)
                if (new_snowflake.pixels[x][y] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
        // top half of left horizontal branch
        for (int x = snowflake_pixel_size/2; x >= 0; x--)
            for (int y = snowflake_pixel_size/2; y >= x; y--)
                if (new_snowflake.pixels[x][y] == 1)
                    new_snowflake.pixels[y][x] = 1;
                
    }  // end generate random snowflake pattern
    
    snowflakes[num_snowflakes] = new_snowflake;
    num_snowflakes++;
}

void draw_snowflakes() {
    short int color = 0xFFFF;
    for (int i = 0; i < num_snowflakes; i++) {
        int dx = (rand() % 3) - 1;
        
        for (int x = 0; x < snowflake_pixel_size; x++)
            for (int y = 0; y < snowflake_pixel_size; y++)
                if (snowflakes[i].pixels[y][x] == 1)
                    plot_pixel(snowflakes[i].x + x + dx, snowflakes[i].y + y + y_drop, color);
        
        snowflakes[i].x += dx;
        snowflakes[i].y += y_drop;
        
        if (rand() % 2 == 0)
            rotate_snowflake(i);
    }
    
    // delete out-of-bounds snowflakes
    int i = 0;
    while (i < num_snowflakes) {
        if (snowflakes[i].y >= 240) {
            // shift elements of array
            for (int j = i; j < num_snowflakes - 1; j++) {
                snowflakes[j] = snowflakes[j + 1];
            }
            
            num_snowflakes--;
        } else {
            i++;   
        }
    }
}

void rotate_snowflake(int index) {
    int angle = (rand() % 2 == 0) ? 45 : -45;
    
    // TODO: rotate snowflake by angle
}

void plot_pixel(int x, int y, short int color) {
    if (y >= 240 || x >= 320)
        return;
    
    *(short int*) (pixel_buffer_start + (y << 10) + (x << 1)) = color;
}

void clear_screen() {
    for (int x = 0; x < 320; x++)
        for (int y = 0; y < 240; y++)
            plot_pixel(x, y, 0);
}

void wait_for_vsync() {
    volatile int *pixel_ctrl_ptr = (int*) 0xFF203020;
    *pixel_ctrl_ptr = 1;
    int status;
    
    while ((status = *(pixel_ctrl_ptr + 3) & 0x01) != 0) ;
}
