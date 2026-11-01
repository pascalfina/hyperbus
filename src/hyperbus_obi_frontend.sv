
module hyperbus_obi_frontend #(

    parameter int unsigned ObiAddrWidth = 32,
    parameter int unsigned ObiDataWidth = 32,
    parameter int unsigned ObiIdWidth = 4,
    parameter int unsigned HostAddrWidth = 32,
    parameter int unsigned HostDataWidth = 32,

    parameter type obi_req_t  = logic,
    parameter type obi_rsp_t  = logic,
    parameter type host_req_t = logic,
    parameter type host_rsp_t = logic

) (
    // signals for midend
    input logic clk_i,
    input logic rst_ni,
    input logic drain_i,
    input obi_req_t obi_req_i,
    input host_rsp_t host_rsp_i,

    output obi_rsp_t obi_rsp_o,
    output logic idle_o,
    output host_req_t host_req_o, 

    //tag crtl signals
    input logic tag_req_ready_i,
    input logic tag_ready_i, 
    input logic tag_error_i,
    input logic read_tag_i,
    input logic read_tag_valid_i,


    output logic tag_access_o, 
    output logic [31:0] tag_addr_o,
    output logic tag_we_o,
    output logic tag_write_tag_o,
    output logic data_done_o, 
    output logic data_error_o

);


generate
    if (ObiDataWidth != 32 || HostDataWidth != 32) begin : gen_invalid_data_width
        $error("OBI frontend supports only 32-bit OBI and host data.");
    end

    if (ObiAddrWidth != 32 || HostAddrWidth != 32) begin : gen_invalid_addr_width
        $error("OBI frontend supports only 32-bit addresses.");
    end

    if ($bits(obi_req_i.a.addr)  != ObiAddrWidth ||
        $bits(obi_req_i.a.wdata) != ObiDataWidth ||
        $bits(obi_rsp_o.r.rdata) != ObiDataWidth) begin : gen_invalid_obi_fields
        $error("OBI struct widths do not match the configured parameters.");
    end

    if (ObiIdWidth < 1 ||
        $bits(obi_req_i.a.aid) != ObiIdWidth ||
        $bits(obi_rsp_o.r.rid) != ObiIdWidth) begin : gen_invalid_id_width
        $error("OBI request and response ID widths must match ObiIdWidth.");
    end

    if ($bits(host_req_o.cmd.addr) != HostAddrWidth ||
        $bits(host_req_o.w.data)   != HostDataWidth ||
        $bits(host_rsp_i.r.data)   != HostDataWidth) begin : gen_invalid_host_fields
        $error("Host struct widths do not match the configured parameters.");
    end

    if ($bits(obi_req_i.a.be)   != 4 ||
        $bits(host_req_o.w.strb) != 4) begin : gen_invalid_byte_masks
        $error("OBI byte enable and host write strobe must each be 4 bits wide.");
    end
endgenerate

typedef enum logic [3:0] {
    IDLE,
    CHECK,
    SEND_COMMAND, 
    WAIT_READ, 
    SEND_WRITE,
    WAIT_WRITE,
    RESPOND,
    TAG_REQUEST,
    WAIT_TAG_DONE
} state_t;


state_t state_q, state_d;

// obi signals

logic [ObiAddrWidth-1:0] obi_addr_q, obi_addr_d;
logic obi_we_q, obi_we_d;
logic [3:0] obi_be_q, obi_be_d;
logic [ObiDataWidth-1:0] obi_wdata_q, obi_wdata_d;
logic [ObiIdWidth-1:0] obi_aid_q, obi_aid_d; 

logic [HostDataWidth-1:0] host_rdata_q, host_rdata_d;

logic [1:0] lower_addr;
logic err_d, err_q;

logic idle;

logic obi_write_tag_q, obi_write_tag_d;
logic obi_read_tag_q, obi_read_tag_d;

assign idle_o = idle;
assign lower_addr = obi_addr_q[1:0];


// valid during SEND_COMMAND
assign host_req_o.cmd.write = obi_we_q;
assign host_req_o.cmd.addr = {obi_addr_q[ObiAddrWidth-1:2], 2'b00};
assign host_req_o.cmd.beats = 1;
assign host_req_o.cmd.size = 2;
assign host_req_o.cmd.burst = hyperbus_pkg::HyperBurstIncr;
assign host_req_o.cmd.atomic_op = hyperbus_pkg::HyperAtomicNone;
assign host_req_o.cmd.atomic_return = 0;
assign host_req_o.cmd.ordered = 0;


// valid during SEND_WRITE
assign host_req_o.w.data = obi_wdata_q;
assign host_req_o.w.strb = obi_be_q;
assign host_req_o.w.last = 1;


// valid during RESPOND
assign obi_rsp_o.r.rid = obi_aid_q;
assign obi_rsp_o.r.rdata = host_rdata_q;
assign obi_rsp_o.r.err = err_q;


//with tag
assign obi_rsp_o.r.r_optional = obi_read_tag_q;


//valid during TAG_REQUEST
assign tag_addr_o = obi_addr_q;
assign tag_we_o = obi_we_q; 
assign tag_write_tag_o = err_q ? 0 : obi_write_tag_q;




always_comb begin
    state_d = state_q;

    obi_addr_d = obi_addr_q;
    obi_we_d = obi_we_q;
    obi_wdata_d = obi_wdata_q;
    obi_aid_d = obi_aid_q;
    err_d = err_q;

    obi_write_tag_d = obi_write_tag_q;
    obi_read_tag_d = obi_read_tag_q; 

    obi_be_d = obi_be_q;

    host_rdata_d = host_rdata_q;

    idle = 0;

    obi_rsp_o.gnt = 0;
    obi_rsp_o.rvalid = 0;

    host_req_o.cmd_valid = 0;
    host_req_o.w_valid = 0;
    host_req_o.r_ready = 0;
    host_req_o.wrsp_ready = 0;

    tag_access_o = 0;
    data_done_o = 0;
    data_error_o = 0;


    case (state_q)
        IDLE: begin
            idle = 1;
            err_d = 0;

            if (!drain_i) begin // only grant if hyperbus is not drained
                obi_rsp_o.gnt = 1;
            end
            if (obi_rsp_o.gnt && obi_req_i.req) begin // incoming msg
                obi_addr_d = obi_req_i.a.addr;
                obi_we_d = obi_req_i.a.we;
                obi_be_d = obi_req_i.a.be;
                obi_wdata_d = obi_req_i.a.wdata;
                obi_aid_d = obi_req_i.a.aid;
                obi_write_tag_d = obi_req_i.a.a_optional;
                state_d = CHECK;
            end
        end

        CHECK: begin
            // if (lower_addr != 2'b0) begin //wrong address format
            //     err_d = 1;
            //     state_d = RESPOND;
            // end 

            if (obi_be_q == 4'b0000) begin //wrong be format
                err_d = 1;
                state_d = RESPOND;
            end
            else begin
                state_d = SEND_COMMAND;
            end  
        end

        SEND_COMMAND: begin
            host_req_o.cmd_valid = 1; // tell the host ther will be valid meta data 
            
            if (host_rsp_i.cmd_ready && host_req_o.cmd_valid) begin // midend was ready 
                state_d = obi_we_d ? SEND_WRITE : WAIT_READ;
            end   
        end

        WAIT_READ: begin
            host_req_o.r_ready = 1; //ready to receive data

            if (host_rsp_i.r_valid && host_req_o.r_ready) begin //midend read data ready
                host_rdata_d = host_rsp_i.r.data;
                err_d = (host_rsp_i.r.resp == hyperbus_pkg::HyperRespOkay && host_rsp_i.r.last == 1) ? 0 : 1;
                 //since burst is not enbaled yet this hould be always 1
                state_d = TAG_REQUEST; 
            end 
        end

        SEND_WRITE: begin
            host_req_o.w_valid = 1;
            
            if (host_req_o.w_valid && host_rsp_i.w_ready) begin
                state_d = WAIT_WRITE;
            end
        end

        WAIT_WRITE: begin
            host_req_o.wrsp_ready = 1; // ready to receive write confirmation

            if (host_rsp_i.wrsp_valid && host_req_o.wrsp_ready) begin

                if (host_rsp_i.wrsp.resp == hyperbus_pkg::HyperRespOkay) begin
                    err_d = 0;
                    state_d = TAG_REQUEST;
                end 
                else begin
                    err_d = 1;
                    state_d = RESPOND;
                end
                
            end
        end

        TAG_REQUEST: begin

            tag_access_o = 1;
            // tag_addr_o = obi_addr_q;
            // tag_we_o = obi_we_q; 
            // tag_write_tag_o = err_q ? 0 : obi_tag_q;

            if (tag_req_ready_i) begin
                state_d = WAIT_TAG_DONE;
            end
            
        end

        WAIT_TAG_DONE: begin

            if (obi_we_q) begin
                data_done_o = 1;
                data_error_o = err_q;
            end 
            else begin
                if (read_tag_valid_i) begin
                    obi_read_tag_d = read_tag_i;
                end
            end

            if (tag_ready_i) begin
                state_d = RESPOND;
            end
        end

        RESPOND: begin
            obi_rsp_o.rvalid = 1;

            state_d = IDLE;   
        end

        default: begin
            state_d = IDLE;
        end
    endcase
end


always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        state_q <= IDLE;
        obi_addr_q <= 32'b0;
        obi_be_q <= 0;
        obi_we_q <= 0;
        obi_wdata_q <= 32'b0;
        obi_aid_q <= 0;
        err_q <= 0;
        host_rdata_q <= 0;
        obi_write_tag_q <= 0;
        obi_read_tag_q <= 0;
    end
    else begin
        state_q <= state_d;
        obi_addr_q <= obi_addr_d;
        obi_we_q <= obi_we_d;
        obi_wdata_q <= obi_wdata_d;
        obi_aid_q <= obi_aid_d;
        obi_be_q <= obi_be_d;
        err_q <= err_d;
        host_rdata_q <= host_rdata_d;
        obi_write_tag_q <= obi_write_tag_d; 
        obi_read_tag_q <= obi_read_tag_d;
    end
    
end


// synthesis translate_off
always @(posedge clk_i) begin
    if (rst_ni && state_q == WAIT_READ &&
        host_rsp_i.r_valid && host_req_o.r_ready &&
        !host_rsp_i.r.last) begin
        $fatal(1, "HyperBus protocol error: single-beat read without last.");
    end
end
// synthesis translate_on

endmodule
