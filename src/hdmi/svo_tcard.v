`timescale 1ns / 1ps
`include "svo_defines.vh"

// If SVO_XYBITS is not defined in svo_defines.vh, define it here (10 bits supports up to ~1024 pixels)
`ifndef SVO_XYBITS
  `define SVO_XYBITS 10
`endif

module svo_tcard #( `SVO_DEFAULT_PARAMS ) (
    input clk, resetn,
    output reg out_axis_tvalid,
    input      out_axis_tready,
    output reg [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
    output reg [0:0] out_axis_tuser
);
    `SVO_DECLS

    //-------------------------------------------------------------------------
    // Game Geometry and Colors (Assuming a 24-bit color depth)
    //-------------------------------------------------------------------------
    // Pong elements are rendered in white on a black background.
    localparam [SVO_BITS_PER_PIXEL-1:0] WHITE = 24'hFFFFFF;
    localparam [SVO_BITS_PER_PIXEL-1:0] BLACK = 24'h000000;

    // Paddle dimensions (in pixels)
    localparam integer PADDLE_WIDTH  = 8;
    localparam integer PADDLE_HEIGHT = 64;
    // Position of left paddle (fixed x)
    localparam integer LEFT_PADDLE_X  = 16;
    // Position of right paddle (fixed x)
    localparam integer RIGHT_PADDLE_X = SVO_HOR_PIXELS - PADDLE_WIDTH - 16;

    // Ball dimensions (square ball)
    localparam integer BALL_SIZE = 8;

    //-------------------------------------------------------------------------
    // Game State Registers
    //-------------------------------------------------------------------------
    // Ball position and velocity
    reg [`SVO_XYBITS-1:0] ball_x;
    reg [`SVO_XYBITS-1:0] ball_y;
    reg signed [3:0] ball_dx;
    reg signed [3:0] ball_dy;

    // Left paddle vertical position and velocity
    reg [`SVO_XYBITS-1:0] left_paddle_y;
    reg signed [3:0]      left_paddle_dy;

    // Right paddle vertical position and velocity
    reg [`SVO_XYBITS-1:0] right_paddle_y;
    reg signed [3:0]      right_paddle_dy;

    //-------------------------------------------------------------------------
    // Pixel Counters for Video Generation
    //-------------------------------------------------------------------------
    reg [`SVO_XYBITS-1:0] hcursor;
    reg [`SVO_XYBITS-1:0] vcursor;

    //-------------------------------------------------------------------------
    // Game Update Logic: Update once per frame
    //-------------------------------------------------------------------------
    // At the start-of-frame (when hcursor==0 and vcursor==0) update the game state.
    always @(posedge clk) begin
        if (!resetn) begin
            // Initialize ball at center with initial velocity.
            ball_x <= SVO_HOR_PIXELS/2 - BALL_SIZE/2;
            ball_y <= SVO_VER_PIXELS/2 - BALL_SIZE/2;
            ball_dx <= 3;
            ball_dy <= 2;
            // Initialize paddles centered vertically.
            left_paddle_y  <= (SVO_VER_PIXELS - PADDLE_HEIGHT)/2;
            left_paddle_dy <= 2;
            right_paddle_y <= (SVO_VER_PIXELS - PADDLE_HEIGHT)/2;
            right_paddle_dy <= -2;
        end else if ((hcursor == 0) && (vcursor == 0)) begin
            // --- Paddle updates ---
            // Update left paddle position and bounce at top/bottom.
            left_paddle_y <= left_paddle_y + left_paddle_dy;
            if ((left_paddle_y + left_paddle_dy) <= 0 ||
                (left_paddle_y + left_paddle_dy) >= (SVO_VER_PIXELS - PADDLE_HEIGHT))
                left_paddle_dy <= -left_paddle_dy;
            
            // Update right paddle position and bounce.
            right_paddle_y <= right_paddle_y + right_paddle_dy;
            if ((right_paddle_y + right_paddle_dy) <= 0 ||
                (right_paddle_y + right_paddle_dy) >= (SVO_VER_PIXELS - PADDLE_HEIGHT))
                right_paddle_dy <= -right_paddle_dy;
            
            // --- Ball update ---
            ball_x <= ball_x + ball_dx;
            ball_y <= ball_y + ball_dy;
            
            // Bounce off top and bottom edges.
            if ((ball_y + ball_dy) <= 0 || (ball_y + ball_dy) >= (SVO_VER_PIXELS - BALL_SIZE))
                ball_dy <= -ball_dy;
            
            // Check collision with left paddle.
            if ((ball_x <= (LEFT_PADDLE_X + PADDLE_WIDTH)) &&
                ((ball_x + BALL_SIZE) >= LEFT_PADDLE_X) &&
                (ball_y + BALL_SIZE > left_paddle_y) &&
                (ball_y < left_paddle_y + PADDLE_HEIGHT)) begin
                if (ball_dx < 0)
                    ball_dx <= -ball_dx;
            end else if (ball_x < 0) begin
                // Ball missed left paddle: reset ball to center.
                ball_x <= SVO_HOR_PIXELS/2 - BALL_SIZE/2;
                ball_y <= SVO_VER_PIXELS/2 - BALL_SIZE/2;
                ball_dx <= 3;
                ball_dy <= 2;
            end
            
            // Check collision with right paddle.
            if ((ball_x + BALL_SIZE >= RIGHT_PADDLE_X) &&
                (ball_x <= RIGHT_PADDLE_X + PADDLE_WIDTH) &&
                (ball_y + BALL_SIZE > right_paddle_y) &&
                (ball_y < right_paddle_y + PADDLE_HEIGHT)) begin
                if (ball_dx > 0)
                    ball_dx <= -ball_dx;
            end else if (ball_x > SVO_HOR_PIXELS - BALL_SIZE) begin
                // Ball missed right paddle: reset ball.
                ball_x <= SVO_HOR_PIXELS/2 - BALL_SIZE/2;
                ball_y <= SVO_VER_PIXELS/2 - BALL_SIZE/2;
                ball_dx <= -3;
                ball_dy <= 2;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Video Pixel Generation
    //-------------------------------------------------------------------------
    // The pixel generator runs every clock cycle, reading (hcursor, vcursor)
    // and drawing the game elements as follows:
    // - If the current pixel lies within the left paddle area, right paddle area,
    //   or ball area, output white.
    // - Otherwise, output a black background.
    // The start-of-frame (tuser) flag is asserted when hcursor and vcursor are zero.
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            hcursor         <= 0;
            vcursor         <= 0;
            out_axis_tvalid <= 0;
            out_axis_tdata  <= 0;
            out_axis_tuser  <= 0;
        end else if (!out_axis_tvalid || out_axis_tready) begin
            out_axis_tvalid <= 1;
            // Set start-of-frame flag.
            out_axis_tuser[0] <= (hcursor == 0 && vcursor == 0);

            // Check if the current pixel lies within any game element.
            if ( (hcursor >= LEFT_PADDLE_X) && (hcursor < LEFT_PADDLE_X + PADDLE_WIDTH) &&
                 (vcursor >= left_paddle_y) && (vcursor < left_paddle_y + PADDLE_HEIGHT) )
                out_axis_tdata <= WHITE;
            else if ( (hcursor >= RIGHT_PADDLE_X) && (hcursor < RIGHT_PADDLE_X + PADDLE_WIDTH) &&
                      (vcursor >= right_paddle_y) && (vcursor < right_paddle_y + PADDLE_HEIGHT) )
                out_axis_tdata <= WHITE;
            else if ( (hcursor >= ball_x) && (hcursor < ball_x + BALL_SIZE) &&
                      (vcursor >= ball_y) && (vcursor < ball_y + BALL_SIZE) )
                out_axis_tdata <= WHITE;
            else
                out_axis_tdata <= BLACK;
            
            // Advance pixel counters.
            if (hcursor == SVO_HOR_PIXELS - 1) begin
                hcursor <= 0;
                if (vcursor == SVO_VER_PIXELS - 1)
                    vcursor <= 0;
                else
                    vcursor <= vcursor + 1;
            end else begin
                hcursor <= hcursor + 1;
            end
        end
    end

endmodule
