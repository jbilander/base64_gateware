package sdram_pkg;

import board_pkg::*;

typedef struct {
	bit [SDRAM_DATA_WIDTH-1:0] d;
} sdram_in;

typedef struct {
	bit [SDRAM_ROW_BITS-1:0] a;
	bit [1:0] ba;
	bit cs;
	bit ras;
	bit cas;
	bit we;
	bit [SDRAM_DATA_WIDTH/8-1:0] dqm;
	bit cke;
	bit [SDRAM_DATA_WIDTH-1:0] q;
	bit drive;
} sdram_out;

typedef struct {
	bit req;
	bit burst;
	bit [SDRAM_ROW_BITS+SDRAM_COLUMN_BITS+2:0] addr;
	bit [15:0] d;
	bit [1:0] dm;
	bit we;
} sdram_request;

typedef struct {
	bit ack;
	bit fill;
	bit [15:0] q;
} sdram_response;

endpackage
